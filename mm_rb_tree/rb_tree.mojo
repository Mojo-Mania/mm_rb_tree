"""A sorted set backed by a red-black tree in owned buffers.

`RBTree` stores its nodes the way `mm_fiby_tree` does -- the elements in one
buffer, every index the tree needs in another divided into regions, addressed
by index rather than by pointer -- and balances them the red-black way, so the
tree stays within a factor of two of the shortest possible height after every
insert and every delete, with no rebuild pass.

Each node carries a left child, a right child, a parent and a colour. The
parent links are what make the balancing rotations possible, and they also give
an in-order walk that needs no stack at all.

```mojo
from mm_rb_tree import RBTree

var set = RBTree[Int]()
set.add(13)
set.add(7)
print(7 in set)                # True
print(set.sorted_elements())   # [7, 13]
```
"""

from std.memory import (
    unsafe_destroy_n,
    unsafe_memcpy,
    unsafe_uninit_copy_n,
    unsafe_uninit_move_n,
)
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc


def _bit_width(n: Int) -> Int:
    """Returns the number of bits needed to represent `n`.

    Args:
        n: A non-negative integer.

    Returns:
        The position of the highest set bit, or 0 for 0.
    """
    var value = n
    var width = 0
    while value > 0:
        value >>= 1
        width += 1
    return width


comptime _MIN_CAPACITY = 8
"""Slots the first growth reserves, so a small set does not reallocate its way
up from one."""

comptime _UNION = 0
comptime _INTERSECTION = 1
comptime _DIFFERENCE = 2
comptime _SYMMETRIC_DIFFERENCE = 3
comptime _OTHER_DIFFERENCE = 4


struct RBTree[
    T: Comparable & Copyable & Deinitable,
    I: DType = DType.uint32,
    growth_percent: Int = 200,
](Boolable, Copyable, Equatable, Iterable, Movable, Sized):
    """A sorted set of unique elements, kept balanced by red-black rules.

    Parameters:
        T: The element type. Must be ordered (`Comparable`) and storable.
        I: The unsigned integer type used for node indices. The default
            `uint32` allows a little over four billion elements; `uint16`
            quarters the memory the links take but caps the set at 65535.
        growth_percent: How much to grow the buffers by when they fill, as a
            percentage of the current capacity; 200 doubles. One buffer holds
            every link region, so over-allocating costs `_REGIONS` times what
            it would for a single array.

    Every operation is O(log n) worst case, which is the point: no input order
    degrades it, and nothing has to be rebuilt afterwards.
    """

    comptime Index = Scalar[Self.I]
    """The scalar type used for node indices."""

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _RBTreeIter[
        Self.T, Self.I, Self.growth_percent, iterable_origin
    ]
    """The iterator returned by `__iter__`, yielding elements in order."""

    comptime _NIL = 0
    """Slot 0 is a sentinel standing for "no node". It is always black, which
    is what lets the balancing code treat a missing child like any other."""
    comptime _LEFT = 0
    """Region holding each node's left child."""
    comptime _RIGHT = 1
    """Region holding each node's right child."""
    comptime _PARENT = 2
    """Region holding each node's parent."""
    comptime _COLOR = 3
    """Region holding each node's colour: 1 for red, 0 for black."""
    comptime _REGIONS = 4
    """How many regions the link buffer is divided into."""

    var _elements: Pointer[Self.T, MutUntrackedOrigin]
    """The element of every node slot; `_count` of them are initialized, with
    slot 0 holding a never-read placeholder for the sentinel."""
    var _links: Pointer[Self.Index, MutUntrackedOrigin]
    """Every index the tree needs, in one allocation: `_REGIONS` regions of
    `_capacity` entries each."""
    var _capacity: Int
    """Slots the buffers can hold, and the stride between link regions."""
    var _count: Int
    """Slots in use, the sentinel included. Slots stay dense: deleting a node
    moves the last one into the gap."""
    var _root: Int
    """The root node, or `_NIL` when the set is empty."""

    # ===-------------------------------------------------------------------===#
    # Lifecycle
    # ===-------------------------------------------------------------------===#

    def __init__(out self, *, capacity: Int = 0):
        """Constructs an empty set.

        Args:
            capacity: Elements to allocate room for up front. Passing the
                eventual element count avoids every intermediate reallocation.
        """
        comptime assert (
            Self.growth_percent > 100
        ), "growth_percent must exceed 100, or the buffers could never grow"
        var slots = capacity + 1 if capacity > 0 else 1
        self._elements = Self._alloc_elements(slots)
        self._links = Self._alloc_links(slots)
        self._capacity = slots
        self._count = 1
        self._root = Self._NIL
        # The sentinel: black, and pointing at itself on every side.
        for region in range(Self._REGIONS):
            self._set(region, Self._NIL, 0)

    def __init__(out self, elements: List[Self.T]):
        """Constructs a set holding the unique values of `elements`.

        Args:
            elements: The values to insert. Duplicates are ignored.
        """
        self = Self(capacity=len(elements))
        for element in elements:
            self.add(element)

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy of `copy`.

        Args:
            copy: The set to duplicate.
        """
        self._capacity = copy._capacity
        self._count = copy._count
        self._root = copy._root
        self._elements = Self._alloc_elements(copy._capacity)
        self._links = Self._alloc_links(copy._capacity)
        unsafe_uninit_copy_n[overlapping=False](
            dest=self._elements, src=copy._elements, count=copy._count
        )
        unsafe_memcpy(
            dest=self._links,
            src=copy._links,
            count=copy._capacity * Self._REGIONS,
        )

    def __init__(out self, *, deinit move: Self):
        """Takes over `move`'s storage.

        Args:
            move: The set to move from.
        """
        self._elements = move._elements
        self._links = move._links
        self._capacity = move._capacity
        self._count = move._count
        self._root = move._root

    def __deinit__(deinit self):
        """Destroys the live elements and releases both buffers."""
        unsafe_destroy_n(self._elements, self._count)
        Self._free_elements(self._elements, self._capacity)
        Self._free_links(self._links, self._capacity)

    # ===-------------------------------------------------------------------===#
    # Storage
    # ===-------------------------------------------------------------------===#

    @staticmethod
    def _alloc_elements(slots: Int) -> Pointer[Self.T, MutUntrackedOrigin]:
        return alloc(Layout[Self.T](count=slots)).unsafe_leak()

    @staticmethod
    def _alloc_links(slots: Int) -> Pointer[Self.Index, MutUntrackedOrigin]:
        return alloc(
            Layout[Self.Index](count=slots * Self._REGIONS)
        ).unsafe_leak()

    @staticmethod
    def _free_elements(
        var pointer: Pointer[Self.T, MutUntrackedOrigin], slots: Int
    ):
        dealloc(
            ThinAllocation(unsafe_owned_ptr=pointer).unsafe_with_layout(
                Layout[Self.T](count=slots)
            )
        )

    @staticmethod
    def _free_links(
        var pointer: Pointer[Self.Index, MutUntrackedOrigin], slots: Int
    ):
        dealloc(
            ThinAllocation(unsafe_owned_ptr=pointer).unsafe_with_layout(
                Layout[Self.Index](count=slots * Self._REGIONS)
            )
        )

    @always_inline
    def _get(self, region: Int, node: Int) -> Int:
        return Int(self._links[unsafe_offset=region * self._capacity + node])

    @always_inline
    def _set(mut self, region: Int, node: Int, value: Int):
        self._links[unsafe_offset=region * self._capacity + node] = Self.Index(
            value
        )

    @always_inline
    def _element(ref self, node: Int) -> ref[self] Self.T:
        return self._elements[unsafe_offset=node]

    @always_inline
    def _left(self, node: Int) -> Int:
        return Int(self._links[unsafe_offset=node])

    @always_inline
    def _set_left(mut self, node: Int, value: Int):
        self._links[unsafe_offset=node] = Self.Index(value)

    @always_inline
    def _right(self, node: Int) -> Int:
        return Int(self._links[unsafe_offset=self._capacity + node])

    @always_inline
    def _set_right(mut self, node: Int, value: Int):
        self._links[unsafe_offset=self._capacity + node] = Self.Index(value)

    @always_inline
    def _parent(self, node: Int) -> Int:
        return self._get(Self._PARENT, node)

    @always_inline
    def _set_parent(mut self, node: Int, value: Int):
        self._set(Self._PARENT, node, value)

    @always_inline
    def _is_red(self, node: Int) -> Bool:
        return self._get(Self._COLOR, node) != 0

    @always_inline
    def _set_red(mut self, node: Int, red: Bool):
        self._set(Self._COLOR, node, 1 if red else 0)

    @always_inline
    def _reserve(mut self, needed: Int):
        """Makes room for `needed` slots, growing only when it has to."""
        if needed > self._capacity:
            self._grow(needed)

    @no_inline
    def _grow(mut self, needed: Int):
        """Reallocates both buffers, moving the elements in one relocation and
        each link region in one `memcpy`."""
        var capacity = self._capacity * Self.growth_percent // 100
        if capacity < _MIN_CAPACITY:
            capacity = _MIN_CAPACITY
        if capacity < needed:
            capacity = needed

        var elements = Self._alloc_elements(capacity)
        unsafe_uninit_move_n[overlapping=False](
            dest=elements, src=self._elements, count=self._count
        )
        Self._free_elements(self._elements, self._capacity)
        self._elements = elements

        var links = Self._alloc_links(capacity)
        for region in range(Self._REGIONS):
            unsafe_memcpy(
                dest=links.unsafe_offset(region * capacity),
                src=self._links.unsafe_offset(region * self._capacity),
                count=self._count,
            )
        Self._free_links(self._links, self._capacity)
        self._links = links
        self._capacity = capacity

    # ===-------------------------------------------------------------------===#
    # Size and membership
    # ===-------------------------------------------------------------------===#

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of elements in the set.

        Returns:
            The element count.
        """
        return self._count - 1

    @always_inline
    def __bool__(self) -> Bool:
        """Returns whether the set is non-empty.

        Returns:
            True if the set holds at least one element.
        """
        return self._count > 1

    def capacity(self) -> Int:
        """Returns how many elements the buffers can hold without growing.

        Returns:
            The element capacity.
        """
        return self._capacity - 1

    def __contains__(self, element: Self.T) -> Bool:
        """Returns whether `element` is in the set.

        Args:
            element: The value to look for.

        Returns:
            True if the set contains an equal element.
        """
        return self._find(element) != Self._NIL

    def _find(self, element: Self.T) -> Int:
        """Returns the node holding `element`, or `_NIL`."""
        var node = self._root
        while node != Self._NIL:
            if element < self._element(node):
                node = self._left(node)
            elif self._element(node) < element:
                node = self._right(node)
            else:
                return node
        return Self._NIL

    def min(self) -> Optional[Self.T]:
        """Returns the smallest element, or `None` if the set is empty.

        Returns:
            The minimum element.
        """
        if self._root == Self._NIL:
            return None
        return self._element(self._minimum(self._root)).copy()

    def max(self) -> Optional[Self.T]:
        """Returns the largest element, or `None` if the set is empty.

        Returns:
            The maximum element.
        """
        if self._root == Self._NIL:
            return None
        var node = self._root
        while self._right(node) != Self._NIL:
            node = self._right(node)
        return self._element(node).copy()

    def height(self) -> Int:
        """Returns the length of the longest root-to-leaf path, in nodes.

        Red-black rules keep this below `2 * log2(len + 1)`, which is what a
        test checks.

        Returns:
            The height, 0 for an empty set.
        """
        return self._height_of(self._root)

    def _height_of(self, node: Int) -> Int:
        if node == Self._NIL:
            return 0
        var left = self._height_of(self._left(node))
        var right = self._height_of(self._right(node))
        return 1 + (left if left > right else right)

    def __eq__(self, other: Self) -> Bool:
        """Returns whether both sets hold the same elements.

        Args:
            other: The set to compare against.

        Returns:
            True if the sets are equal.
        """
        if len(self) != len(other):
            return False
        var mine = self._first()
        var theirs = other._first()
        while mine != Self._NIL:
            if self._element(mine) != other._element(theirs):
                return False
            mine = self._next(mine)
            theirs = other._next(theirs)
        return True

    def __ne__(self, other: Self) -> Bool:
        """Returns whether the sets differ.

        Args:
            other: The set to compare against.

        Returns:
            True if the sets are not equal.
        """
        return not (self == other)

    # ===-------------------------------------------------------------------===#
    # In-order walking, without a stack
    # ===-------------------------------------------------------------------===#

    @always_inline
    def _minimum(self, node: Int) -> Int:
        var current = node
        while self._left(current) != Self._NIL:
            current = self._left(current)
        return current

    def _first(self) -> Int:
        """Returns the smallest node, or `_NIL` when the set is empty."""
        if self._root == Self._NIL:
            return Self._NIL
        return self._minimum(self._root)

    def _next(self, node: Int) -> Int:
        """Returns the node after `node` in order, or `_NIL`.

        Parent links make this a plain walk: no stack, nothing allocated.
        """
        if self._right(node) != Self._NIL:
            return self._minimum(self._right(node))
        var current = node
        var parent = self._parent(current)
        while parent != Self._NIL and current == self._right(parent):
            current = parent
            parent = self._parent(parent)
        return parent

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns an iterator over the elements in ascending order.

        Returns:
            An iterator yielding references to every element, smallest first.
        """
        return {src = Pointer(to=self)}

    def sorted_elements(self) -> List[Self.T]:
        """Returns every element in ascending order.

        Returns:
            A list of the elements, smallest first.
        """
        var result = List[Self.T](capacity=len(self))
        var node = self._first()
        while node != Self._NIL:
            result.append(self._element(node).copy())
            node = self._next(node)
        return result^

    # ===-------------------------------------------------------------------===#
    # Insertion
    # ===-------------------------------------------------------------------===#

    def add(mut self, element: Self.T):
        """Inserts `element`, doing nothing if an equal element is present.

        Args:
            element: The value to insert.
        """
        var parent = Self._NIL
        var node = self._root
        var went_left = False
        while node != Self._NIL:
            parent = node
            if element < self._element(node):
                node = self._left(node)
                went_left = True
            elif self._element(node) < element:
                node = self._right(node)
                went_left = False
            else:
                return

        var fresh = self._new_node(element, parent)
        if parent == Self._NIL:
            self._root = fresh
        elif went_left:
            self._set_left(parent, fresh)
        else:
            self._set_right(parent, fresh)
        self._insert_fixup(fresh)

    def _new_node(mut self, element: Self.T, parent: Int) -> Int:
        var index = self._count
        debug_assert(
            index <= Int(Self.Index.MAX),
            "RBTree: node index type is too narrow for this many elements",
        )
        self._reserve(index + 1)
        self._elements.unsafe_offset(index).unsafe_write(element.copy())
        self._count += 1
        self._set_left(index, Self._NIL)
        self._set_right(index, Self._NIL)
        self._set_parent(index, parent)
        self._set_red(index, True)
        return index

    def _insert_fixup(mut self, var node: Int):
        """Restores the red-black rules after a red node was linked in."""
        while self._is_red(self._parent(node)):
            var parent = self._parent(node)
            var grand = self._parent(parent)
            if parent == self._left(grand):
                var uncle = self._right(grand)
                if self._is_red(uncle):
                    self._set_red(parent, False)
                    self._set_red(uncle, False)
                    self._set_red(grand, True)
                    node = grand
                else:
                    if node == self._right(parent):
                        node = parent
                        self._rotate_left(node)
                        parent = self._parent(node)
                        grand = self._parent(parent)
                    self._set_red(parent, False)
                    self._set_red(grand, True)
                    self._rotate_right(grand)
            else:
                var uncle = self._left(grand)
                if self._is_red(uncle):
                    self._set_red(parent, False)
                    self._set_red(uncle, False)
                    self._set_red(grand, True)
                    node = grand
                else:
                    if node == self._left(parent):
                        node = parent
                        self._rotate_right(node)
                        parent = self._parent(node)
                        grand = self._parent(parent)
                    self._set_red(parent, False)
                    self._set_red(grand, True)
                    self._rotate_left(grand)
        self._set_red(self._root, False)

    def _rotate_left(mut self, node: Int):
        var pivot = self._right(node)
        self._set_right(node, self._left(pivot))
        if self._left(pivot) != Self._NIL:
            self._set_parent(self._left(pivot), node)
        self._set_parent(pivot, self._parent(node))
        if self._parent(node) == Self._NIL:
            self._root = pivot
        elif node == self._left(self._parent(node)):
            self._set_left(self._parent(node), pivot)
        else:
            self._set_right(self._parent(node), pivot)
        self._set_left(pivot, node)
        self._set_parent(node, pivot)

    def _rotate_right(mut self, node: Int):
        var pivot = self._left(node)
        self._set_left(node, self._right(pivot))
        if self._right(pivot) != Self._NIL:
            self._set_parent(self._right(pivot), node)
        self._set_parent(pivot, self._parent(node))
        if self._parent(node) == Self._NIL:
            self._root = pivot
        elif node == self._right(self._parent(node)):
            self._set_right(self._parent(node), pivot)
        else:
            self._set_left(self._parent(node), pivot)
        self._set_right(pivot, node)
        self._set_parent(node, pivot)

    # ===-------------------------------------------------------------------===#
    # Deletion
    # ===-------------------------------------------------------------------===#

    def delete(mut self, element: Self.T) -> Bool:
        """Removes `element` from the set.

        Args:
            element: The value to remove.

        Returns:
            True if the element was present and removed.
        """
        var node = self._find(element)
        if node == Self._NIL:
            return False
        self._remove(node)
        return True

    def clear(mut self):
        """Removes every element, keeping the allocated storage."""
        unsafe_destroy_n(self._elements.unsafe_offset(1), self._count - 1)
        self._count = 1
        self._root = Self._NIL

    def _transplant(mut self, target: Int, replacement: Int):
        """Puts `replacement` where `target` hangs off its parent."""
        var parent = self._parent(target)
        if parent == Self._NIL:
            self._root = replacement
        elif target == self._left(parent):
            self._set_left(parent, replacement)
        else:
            self._set_right(parent, replacement)
        self._set_parent(replacement, parent)

    def _remove(mut self, node: Int):
        var spliced = node
        var spliced_was_red = self._is_red(spliced)
        var orphan: Int

        if self._left(node) == Self._NIL:
            orphan = self._right(node)
            self._transplant(node, self._right(node))
        elif self._right(node) == Self._NIL:
            orphan = self._left(node)
            self._transplant(node, self._left(node))
        else:
            spliced = self._minimum(self._right(node))
            spliced_was_red = self._is_red(spliced)
            orphan = self._right(spliced)
            if self._parent(spliced) == node:
                # `orphan` may be the sentinel; the fixup walks up from it, so
                # it needs a parent to walk to.
                self._set_parent(orphan, spliced)
            else:
                self._transplant(spliced, self._right(spliced))
                self._set_right(spliced, self._right(node))
                self._set_parent(self._right(spliced), spliced)
            self._transplant(node, spliced)
            self._set_left(spliced, self._left(node))
            self._set_parent(self._left(spliced), spliced)
            self._set_red(spliced, self._is_red(node))

        if not spliced_was_red:
            self._delete_fixup(orphan)
        self._release(node)

    def _delete_fixup(mut self, var node: Int):
        """Restores the black-height after a black node left the tree."""
        while node != self._root and not self._is_red(node):
            var parent = self._parent(node)
            if node == self._left(parent):
                var sibling = self._right(parent)
                if self._is_red(sibling):
                    self._set_red(sibling, False)
                    self._set_red(parent, True)
                    self._rotate_left(parent)
                    sibling = self._right(parent)
                if not self._is_red(self._left(sibling)) and not self._is_red(
                    self._right(sibling)
                ):
                    self._set_red(sibling, True)
                    node = parent
                else:
                    if not self._is_red(self._right(sibling)):
                        self._set_red(self._left(sibling), False)
                        self._set_red(sibling, True)
                        self._rotate_right(sibling)
                        sibling = self._right(parent)
                    self._set_red(sibling, self._is_red(parent))
                    self._set_red(parent, False)
                    self._set_red(self._right(sibling), False)
                    self._rotate_left(parent)
                    node = self._root
            else:
                var sibling = self._left(parent)
                if self._is_red(sibling):
                    self._set_red(sibling, False)
                    self._set_red(parent, True)
                    self._rotate_right(parent)
                    sibling = self._left(parent)
                if not self._is_red(self._right(sibling)) and not self._is_red(
                    self._left(sibling)
                ):
                    self._set_red(sibling, True)
                    node = parent
                else:
                    if not self._is_red(self._left(sibling)):
                        self._set_red(self._right(sibling), False)
                        self._set_red(sibling, True)
                        self._rotate_left(sibling)
                        sibling = self._left(parent)
                    self._set_red(sibling, self._is_red(parent))
                    self._set_red(parent, False)
                    self._set_red(self._left(sibling), False)
                    self._rotate_right(parent)
                    node = self._root
        self._set_red(node, False)

    def _release(mut self, dead: Int):
        """Frees a slot by moving the last node into it, keeping slots dense.

        This is what replaces a free list: after it, slots 1 to `_count - 1`
        are exactly the live nodes, so nothing ever needs compacting.
        """
        var last = self._count - 1
        unsafe_destroy_n(self._elements.unsafe_offset(dead), 1)
        if dead != last:
            unsafe_uninit_move_n[overlapping=False](
                dest=self._elements.unsafe_offset(dead),
                src=self._elements.unsafe_offset(last),
                count=1,
            )
            for region in range(Self._REGIONS):
                self._set(region, dead, self._get(region, last))

            if self._left(dead) != Self._NIL:
                self._set_parent(self._left(dead), dead)
            if self._right(dead) != Self._NIL:
                self._set_parent(self._right(dead), dead)
            var parent = self._parent(dead)
            if parent == Self._NIL:
                self._root = dead
            elif self._left(parent) == last:
                self._set_left(parent, dead)
            else:
                self._set_right(parent, dead)
        self._count -= 1

    # ===-------------------------------------------------------------------===#
    # Set operations
    # ===-------------------------------------------------------------------===#

    def union(self, other: Self) -> Self:
        """Returns the elements present in either set.

        Args:
            other: The set to combine with.

        Returns:
            A new set holding the union.
        """
        return Self._from_sorted(self._merge[_UNION](other))

    def union_inplace(mut self, other: Self):
        """Adds every element of `other` to this set.

        Args:
            other: The set to merge in.
        """
        self = Self._from_sorted(self._merge[_UNION](other))

    def intersection(self, other: Self) -> Self:
        """Returns the elements present in both sets.

        Args:
            other: The set to intersect with.

        Returns:
            A new set holding the intersection.
        """
        return Self._from_sorted(self._merge[_INTERSECTION](other))

    def intersection_inplace(mut self, other: Self):
        """Keeps only the elements that are also in `other`.

        Args:
            other: The set to intersect with.
        """
        self = Self._from_sorted(self._merge[_INTERSECTION](other))

    def difference(self, other: Self) -> Self:
        """Returns the elements of this set that are not in `other`.

        Args:
            other: The set to subtract.

        Returns:
            A new set holding the difference.
        """
        return Self._from_sorted(self._merge[_DIFFERENCE](other))

    def difference_inplace(mut self, other: Self):
        """Removes every element of `other` from this set.

        Args:
            other: The set to subtract.
        """
        self = Self._from_sorted(self._merge[_DIFFERENCE](other))

    def other_difference_inplace(mut self, other: Self):
        """Replaces this set with the elements of `other` that it lacks.

        Args:
            other: The set to subtract this one from.
        """
        self = Self._from_sorted(self._merge[_OTHER_DIFFERENCE](other))

    def symmetric_difference(self, other: Self) -> Self:
        """Returns the elements present in exactly one of the two sets.

        Args:
            other: The set to compare with.

        Returns:
            A new set holding the symmetric difference.
        """
        return Self._from_sorted(self._merge[_SYMMETRIC_DIFFERENCE](other))

    def symmetric_difference_inplace(mut self, other: Self):
        """Keeps the elements present in exactly one of the two sets.

        Args:
            other: The set to compare with.
        """
        self = Self._from_sorted(self._merge[_SYMMETRIC_DIFFERENCE](other))

    def is_disjoint(self, other: Self) -> Bool:
        """Returns whether the two sets share no elements.

        Args:
            other: The set to compare with.

        Returns:
            True if the intersection is empty.
        """
        var mine = self._first()
        var theirs = other._first()
        while mine != Self._NIL and theirs != Self._NIL:
            if self._element(mine) < other._element(theirs):
                mine = self._next(mine)
            elif other._element(theirs) < self._element(mine):
                theirs = other._next(theirs)
            else:
                return False
        return True

    def is_subset(self, other: Self) -> Bool:
        """Returns whether every element of this set is in `other`.

        Args:
            other: The candidate superset.

        Returns:
            True if this set is a subset of `other`.
        """
        if len(self) > len(other):
            return False
        var mine = self._first()
        var theirs = other._first()
        while mine != Self._NIL:
            if theirs == Self._NIL:
                return False
            if self._element(mine) < other._element(theirs):
                return False
            elif other._element(theirs) < self._element(mine):
                theirs = other._next(theirs)
            else:
                mine = self._next(mine)
                theirs = other._next(theirs)
        return True

    def is_superset(self, other: Self) -> Bool:
        """Returns whether this set contains every element of `other`.

        Args:
            other: The candidate subset.

        Returns:
            True if this set is a superset of `other`.
        """
        return other.is_subset(self)

    def _merge[op: Int](self, other: Self) -> List[Self.T]:
        """Walks both sets in order and collects the result of `op`."""
        var result = List[Self.T](capacity=len(self) + len(other))
        var mine = self._first()
        var theirs = other._first()

        while mine != Self._NIL and theirs != Self._NIL:
            if self._element(mine) < other._element(theirs):
                comptime if (
                    op == _UNION
                    or op == _DIFFERENCE
                    or op == _SYMMETRIC_DIFFERENCE
                ):
                    result.append(self._element(mine).copy())
                mine = self._next(mine)
            elif other._element(theirs) < self._element(mine):
                comptime if (
                    op == _UNION
                    or op == _SYMMETRIC_DIFFERENCE
                    or op == _OTHER_DIFFERENCE
                ):
                    result.append(other._element(theirs).copy())
                theirs = other._next(theirs)
            else:
                comptime if op == _UNION or op == _INTERSECTION:
                    result.append(self._element(mine).copy())
                mine = self._next(mine)
                theirs = other._next(theirs)

        comptime if (
            op == _UNION or op == _DIFFERENCE or op == _SYMMETRIC_DIFFERENCE
        ):
            while mine != Self._NIL:
                result.append(self._element(mine).copy())
                mine = self._next(mine)

        comptime if (
            op == _UNION
            or op == _SYMMETRIC_DIFFERENCE
            or op == _OTHER_DIFFERENCE
        ):
            while theirs != Self._NIL:
                result.append(other._element(theirs).copy())
                theirs = other._next(theirs)

        return result^

    @staticmethod
    def _from_sorted(var sorted: List[Self.T]) -> Self:
        """Builds a set from an ascending, duplicate-free list, in O(n).

        Inserting one at a time would cost O(n log n) and a rotation storm.
        A sorted list already describes the shape: split at the middle,
        recurse, and colour only the deepest level red. Every path then crosses
        the same number of black nodes, because the red nodes are all leaves.
        """
        var size = len(sorted)
        var result = Self(capacity=size)
        if size == 0:
            return result^
        # The level beyond the perfect prefix. When `size + 1` is a power of
        # two the tree is perfect and nothing is red.
        var red_depth = _bit_width(size + 1) - 1
        result._root = result._build_balanced(
            sorted, 0, size - 1, 0, Self._NIL, red_depth
        )
        return result^

    def _build_balanced(
        mut self,
        sorted: List[Self.T],
        low: Int,
        high: Int,
        depth: Int,
        parent: Int,
        red_depth: Int,
    ) -> Int:
        """Builds the subtree for `sorted[low .. high]` and returns its root."""
        if low > high:
            return Self._NIL
        var mid = (low + high) // 2
        var node = self._new_node(sorted[mid], parent)
        self._set_red(node, depth == red_depth)
        self._set_left(
            node,
            self._build_balanced(
                sorted, low, mid - 1, depth + 1, node, red_depth
            ),
        )
        self._set_right(
            node,
            self._build_balanced(
                sorted, mid + 1, high, depth + 1, node, red_depth
            ),
        )
        return node


# ===-----------------------------------------------------------------------===#
# Iterator
# ===-----------------------------------------------------------------------===#


struct _RBTreeIter[
    mut: Bool,
    //,
    T: Comparable & Copyable & Deinitable,
    I: DType,
    G: Int,
    origin: Origin[mut=mut],
](Iterator):
    """Yields the elements of an `RBTree` in ascending order.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Self.T

    var _src: Pointer[RBTree[Self.T, Self.I, Self.G], Self.origin]
    var _node: Int
    var _remaining: Int

    def __init__(
        out self, src: Pointer[RBTree[Self.T, Self.I, Self.G], Self.origin]
    ):
        """Starts a walk at the smallest element of `src`.

        Args:
            src: The set to walk.
        """
        self._src = src
        self._node = src[]._first()
        self._remaining = len(src[])

    def __next__(
        mut self,
    ) raises StopIteration -> ref[Self.origin] Self.Element:
        """Returns a reference to the next element in ascending order.

        Nothing is copied, so walking a set of heap-owning elements allocates
        nothing.

        Raises:
            StopIteration: When every element has been yielded.

        Returns:
            A reference to the next smallest element.
        """
        if self._node == 0:
            raise StopIteration()
        var node = self._node
        self._node = self._src[]._next(node)
        self._remaining -= 1
        return self._src[]._elements[unsafe_offset=node]

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        """Returns the exact number of elements left to yield.

        Returns:
            The remaining count as both the lower and the upper bound.
        """
        return (self._remaining, Optional(self._remaining))


def print_tree[
    T: Comparable & Copyable & Deinitable & Writable, I: DType, G: Int, //
](tree: RBTree[T, I, G]):
    """Prints the shape of `tree`, one node per line, with colours marked.

    Parameters:
        T: The element type, which must also be printable.
        I: The index type of the tree.
        G: The tree's growth percentage.

    Args:
        tree: The tree to print.
    """
    if len(tree) == 0:
        print("・")
        return
    _print_node(tree, tree._root, "")


def _print_node[
    T: Comparable & Copyable & Deinitable & Writable, I: DType, G: Int, //
](tree: RBTree[T, I, G], node: Int, indentation: String):
    var mark = "R" if tree._is_red(node) else "B"
    if indentation.byte_length() > 0:
        print(indentation, "-", tree._element(node), "(" + mark + ")")
    else:
        print("-", tree._element(node), "(" + mark + ")")
    if tree._left(node) != 0:
        _print_node(tree, tree._left(node), indentation + " ")
    if tree._right(node) != 0:
        _print_node(tree, tree._right(node), indentation + " ")
