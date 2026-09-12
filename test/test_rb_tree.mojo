from mm_rb_tree import RBTree
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)


def tree(elements: List[Int]) -> RBTree[Int]:
    """Builds a tree by inserting one element at a time."""
    var result = RBTree[Int]()
    for element in elements:
        result.add(element)
    return result^


def assert_rb_valid(tree: RBTree[Int]) raises:
    """Checks every red-black invariant, plus the storage ones.

    1. the root is black
    2. a red node has no red child
    3. every root-to-leaf path crosses the same number of black nodes
    4. the in-order walk is strictly increasing, and as long as `len`
    5. every child agrees with its parent, and the root has none
    6. slots stay dense: 1 .. `_count - 1` are exactly the live nodes
    """
    if len(tree) == 0:
        assert_equal(tree._root, 0, "an empty tree has no root")
        assert_equal(tree._count, 1)
        return

    assert_false(tree._is_red(tree._root), "the root must be black")
    assert_equal(tree._parent(tree._root), 0, "the root has no parent")

    # Walk every node, checking colours, parents, and black-height.
    var black_height = -1
    var seen = 0
    var previous = Optional[Int](None)
    var node = tree._first()
    while node != 0:
        seen += 1
        if tree._is_red(node):
            assert_false(
                tree._is_red(tree._left(node)),
                String("red node ", node, " has a red left child"),
            )
            assert_false(
                tree._is_red(tree._right(node)),
                String("red node ", node, " has a red right child"),
            )
        for child in [tree._left(node), tree._right(node)]:
            if child != 0:
                assert_equal(
                    tree._parent(child),
                    node,
                    String("child ", child, " disagrees about its parent"),
                )
        if previous:
            assert_true(
                previous.value() < tree._element(node),
                "the in-order walk must strictly increase",
            )
        previous = tree._element(node)

        # Leaves anchor the black-height check.
        if tree._left(node) == 0 and tree._right(node) == 0:
            var blacks = 1  # the sentinel below this leaf
            var current = node
            while current != 0:
                if not tree._is_red(current):
                    blacks += 1
                current = tree._parent(current)
            if black_height == -1:
                black_height = blacks
            else:
                assert_equal(
                    blacks,
                    black_height,
                    "every path must cross the same number of black nodes",
                )
        node = tree._next(node)

    assert_equal(seen, len(tree), "the walk must visit every element")
    assert_equal(tree._count, len(tree) + 1, "slots must stay dense")


def assert_elements(tree: RBTree[Int], expected: List[Int]) raises:
    var actual = tree.sorted_elements()
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


# ===-----------------------------------------------------------------------===#
# Basics
# ===-----------------------------------------------------------------------===#


def test_empty_tree() raises:
    var set = RBTree[Int]()
    assert_equal(len(set), 0)
    assert_false(Bool(set))
    assert_false(1 in set)
    assert_equal(len(set.sorted_elements()), 0)
    assert_false(set.delete(1))
    assert_true(set.min() is None)
    assert_true(set.max() is None)


def test_add_and_contains() raises:
    var set = tree([13, 15])
    assert_equal(len(set), 2)
    assert_true(13 in set)
    assert_true(15 in set)
    assert_false(14 in set)


def test_add_is_idempotent() raises:
    var set = tree([5, 5, 5])
    assert_equal(len(set), 1)
    assert_elements(set, [5])


def test_dedup_and_sort() raises:
    var set = tree([5, 6, 3, 8, 11, 34, 56, 12, 48, 11, 9])
    assert_equal(len(set), 10)
    assert_elements(set, [3, 5, 6, 8, 9, 11, 12, 34, 48, 56])


def test_delete_missing_element() raises:
    var set = tree([1, 2, 3])
    assert_false(set.delete(99))
    assert_equal(len(set), 3)


def test_delete_leaf() raises:
    var set = tree([10, 5, 15])
    assert_true(set.delete(5))
    assert_elements(set, [10, 15])


def test_delete_node_with_one_child() raises:
    var set = tree([10, 5, 15, 3])
    assert_true(set.delete(5))
    assert_elements(set, [3, 10, 15])


def test_delete_root_with_only_left_child() raises:
    var set = tree([10, 5, 3])
    assert_true(set.delete(10))
    assert_elements(set, [3, 5])


def test_delete_root_with_only_right_child() raises:
    var set = tree([10, 15, 20])
    assert_true(set.delete(10))
    assert_elements(set, [15, 20])


def test_delete_node_with_two_children() raises:
    var set = tree([10, 5, 15, 3, 7, 12, 20])
    assert_true(set.delete(10))
    assert_elements(set, [3, 5, 7, 12, 15, 20])


def test_delete_two_children_predecessor_has_left_child() raises:
    """Regression: the 2023 version dropped the whole right subtree here.

    Deleting the root of `10(5(3), 15)` walks to the predecessor `5`, which is
    the root's immediate left child and has a left child but no right child.
    The original re-pointed `right[parent]` unconditionally -- and `parent` is
    the root itself on the first step, so `15` was lost and `left[root]` was
    left dangling at the removed node.
    """
    var set = tree([10, 5, 15, 3])
    assert_true(set.delete(10))
    assert_equal(len(set), 3)
    assert_elements(set, [3, 5, 15])
    assert_true(15 in set)
    assert_true(3 in set)
    assert_false(10 in set)


def test_delete_deep_predecessor_with_left_child() raises:
    var set = tree([50, 25, 75, 10, 40, 35, 45, 30])
    assert_true(set.delete(50))
    assert_elements(set, [10, 25, 30, 35, 40, 45, 75])


def test_clear() raises:
    var set = tree([1, 2, 3])
    set.clear()
    assert_equal(len(set), 0)
    assert_false(2 in set)
    set.add(9)
    assert_elements(set, [9])


# ===-----------------------------------------------------------------------===#
# Balancing
# ===-----------------------------------------------------------------------===#


# ===-----------------------------------------------------------------------===#
# min / max
# ===-----------------------------------------------------------------------===#


def test_min_max() raises:
    var set = tree([50, 25, 75, 10, 40, 60, 90])
    assert_equal(set.min().value(), 10)
    assert_equal(set.max().value(), 90)


def test_min_max_single_element() raises:
    var set = tree([42])
    assert_equal(set.min().value(), 42)
    assert_equal(set.max().value(), 42)


# ===-----------------------------------------------------------------------===#
# Iteration
# ===-----------------------------------------------------------------------===#


def test_iteration_is_sorted() raises:
    var set = tree([5, 1, 9, 3, 7])
    var seen = List[Int]()
    for element in set:
        seen.append(element)
    assert_equal(len(seen), 5)
    for i in range(len(seen)):
        assert_equal(seen[i], [1, 3, 5, 7, 9][i])


def test_iteration_over_empty_set() raises:
    var set = RBTree[Int]()
    var count = 0
    for _ in set:
        count += 1
    assert_equal(count, 0)


def test_iteration_after_delete() raises:
    var set = tree([10, 5, 15, 3, 7, 12, 20])
    _ = set.delete(10)
    _ = set.delete(3)
    var seen = List[Int]()
    for element in set:
        seen.append(element)
    assert_equal(len(seen), 5)
    for i in range(len(seen)):
        assert_equal(seen[i], [5, 7, 12, 15, 20][i])


def test_iteration_matches_sorted_elements() raises:
    var set = RBTree[Int]()
    for i in range(200):
        set.add((i * 7919) % 1000)
    var expected = set.sorted_elements()
    var seen = List[Int]()
    for element in set:
        seen.append(element)
    assert_equal(len(seen), len(expected))
    for i in range(len(expected)):
        assert_equal(seen[i], expected[i])


def test_iteration_can_restart() raises:
    var set = tree([2, 1, 3])
    var first = List[Int]()
    for element in set:
        first.append(element)
    var second = List[Int]()
    for element in set:
        second.append(element)
    assert_equal(len(first), 3)
    assert_equal(len(second), 3)
    for i in range(3):
        assert_equal(first[i], second[i])


def test_list_from_iterator() raises:
    var set = tree([5, 1, 9])
    var collected = List(set)
    assert_equal(len(collected), 3)
    assert_equal(collected[0], 1)
    assert_equal(collected[1], 5)
    assert_equal(collected[2], 9)


def test_iteration_over_strings() raises:
    var set = RBTree[String]()
    set.add("pear")
    set.add("apple")
    set.add("fig")
    var seen = List[String]()
    for name in set:
        seen.append(name)
    assert_equal(seen[0], "apple")
    assert_equal(seen[1], "fig")
    assert_equal(seen[2], "pear")


# ===-----------------------------------------------------------------------===#
# Set operations
# ===-----------------------------------------------------------------------===#


def test_union() raises:
    var a = tree([1, 3, 5])
    var b = tree([2, 3, 6])
    assert_elements(a.union(b), [1, 2, 3, 5, 6])
    assert_elements(b.union(a), [1, 2, 3, 5, 6])


def test_union_with_empty() raises:
    var a = tree([1, 2])
    var empty = RBTree[Int]()
    assert_elements(a.union(empty), [1, 2])
    assert_elements(empty.union(a), [1, 2])


def test_union_inplace() raises:
    var a = tree([1, 3, 5])
    a.union_inplace(tree([2, 3, 6]))
    assert_elements(a, [1, 2, 3, 5, 6])


def test_intersection() raises:
    var a = tree([1, 3, 5, 7])
    var b = tree([3, 4, 5, 9])
    assert_elements(a.intersection(b), [3, 5])
    assert_elements(b.intersection(a), [3, 5])


def test_intersection_disjoint_and_empty() raises:
    assert_elements(tree([1, 2]).intersection(tree([3, 4])), [])
    assert_elements(tree([1, 2]).intersection(RBTree[Int]()), [])
    assert_elements(RBTree[Int]().intersection(tree([1, 2])), [])


def test_intersection_inplace() raises:
    var a = tree([1, 3, 5, 7])
    a.intersection_inplace(tree([3, 4, 5, 9]))
    assert_elements(a, [3, 5])


def test_difference() raises:
    var a = tree([1, 3, 5, 7])
    var b = tree([3, 7, 9])
    assert_elements(a.difference(b), [1, 5])
    assert_elements(b.difference(a), [9])


def test_difference_with_empty() raises:
    var a = tree([1, 2])
    assert_elements(a.difference(RBTree[Int]()), [1, 2])
    assert_elements(RBTree[Int]().difference(a), [])


def test_difference_inplace() raises:
    var a = tree([1, 3, 5, 7])
    a.difference_inplace(tree([3, 7, 9]))
    assert_elements(a, [1, 5])


def test_other_difference_inplace() raises:
    var a = tree([1, 3, 5, 7])
    a.other_difference_inplace(tree([3, 7, 9]))
    assert_elements(a, [9])


def test_symmetric_difference() raises:
    var a = tree([1, 3, 5, 7])
    var b = tree([3, 7, 9])
    assert_elements(a.symmetric_difference(b), [1, 5, 9])
    assert_elements(b.symmetric_difference(a), [1, 5, 9])


def test_symmetric_difference_inplace() raises:
    var a = tree([1, 3, 5, 7])
    a.symmetric_difference_inplace(tree([3, 7, 9]))
    assert_elements(a, [1, 5, 9])


def test_set_ops_on_larger_sets() raises:
    var evens = RBTree[Int]()
    var threes = RBTree[Int]()
    for i in range(200):
        evens.add(i * 2)
        threes.add(i * 3)
    var both = evens.intersection(threes)
    for element in both.sorted_elements():
        assert_true(element % 6 == 0)
    assert_equal(len(evens.union(threes)), 400 - len(both))


# ===-----------------------------------------------------------------------===#
# Predicates
# ===-----------------------------------------------------------------------===#


def test_is_disjoint() raises:
    assert_true(tree([1, 3]).is_disjoint(tree([2, 4])))
    assert_false(tree([1, 3]).is_disjoint(tree([3, 4])))
    assert_true(tree([1, 3]).is_disjoint(RBTree[Int]()))
    assert_true(RBTree[Int]().is_disjoint(RBTree[Int]()))


def test_is_subset() raises:
    assert_true(tree([2, 3]).is_subset(tree([1, 2, 3, 4])))
    assert_false(tree([2, 5]).is_subset(tree([1, 2, 3, 4])))
    assert_true(RBTree[Int]().is_subset(tree([1])))
    assert_false(tree([1]).is_subset(RBTree[Int]()))
    assert_true(tree([1, 2]).is_subset(tree([1, 2])))


def test_is_subset_last_element_missing() raises:
    assert_false(tree([1, 2, 9]).is_subset(tree([1, 2, 3])))


def test_is_superset() raises:
    assert_true(tree([1, 2, 3, 4]).is_superset(tree([2, 3])))
    assert_false(tree([1, 2, 3, 4]).is_superset(tree([2, 5])))
    assert_true(tree([1]).is_superset(RBTree[Int]()))


def test_equality() raises:
    assert_true(tree([1, 2, 3]) == tree([3, 2, 1]))
    assert_false(tree([1, 2, 3]) == tree([1, 2]))
    assert_false(tree([1, 2, 3]) == tree([1, 2, 4]))
    assert_true(RBTree[Int]() == RBTree[Int]())
    # Insertion order must not affect equality.
    var built = RBTree[Int]([1, 2, 3])
    assert_true(built == tree([2, 1, 3]))


# ===-----------------------------------------------------------------------===#
# Generality
# ===-----------------------------------------------------------------------===#


def test_string_elements() raises:
    var set = RBTree[String]()
    set.add("pear")
    set.add("apple")
    set.add("fig")
    set.add("apple")
    assert_equal(len(set), 3)
    var sorted = set.sorted_elements()
    assert_equal(sorted[0], "apple")
    assert_equal(sorted[1], "fig")
    assert_equal(sorted[2], "pear")
    assert_true(String("fig") in set)
    assert_false(String("plum") in set)


def test_narrow_index_type() raises:
    var set = RBTree[Int, DType.uint16]()
    for i in range(1000):
        set.add(i)
    assert_equal(len(set), 1000)
    for i in range(1000):
        assert_true(i in set)


def test_construct_from_list() raises:
    var set = RBTree[Int]([5, 1, 5, 3])
    assert_elements(set, [1, 3, 5])


def test_capacity_argument_avoids_growth() raises:
    var set = RBTree[Int](capacity=64)
    assert_equal(set.capacity(), 64)
    for i in range(64):
        set.add(i)
    assert_equal(set.capacity(), 64, "should not have reallocated")
    set.add(99)
    assert_true(set.capacity() > 64)
    assert_rb_valid(set)


def test_growth_percent_controls_capacity() raises:
    var doubling = RBTree[Int]()
    var gentle = RBTree[Int, DType.uint32, 150]()
    for i in range(300):
        doubling.add(i * 7 % 1000)
        gentle.add(i * 7 % 1000)
    assert_equal(len(doubling), len(gentle))
    assert_true(
        gentle._capacity <= doubling._capacity,
        String(
            "150% grew to ",
            gentle._capacity,
            " but 200% grew to ",
            doubling._capacity,
        ),
    )


def test_iteration_does_not_copy_elements() raises:
    """Walking yields references, so the values seen are the stored ones."""
    var set = RBTree[String]()
    set.add("alpha")
    set.add("beta")
    var seen = List[String]()
    for element in set:
        seen.append(element.copy())
    assert_equal(len(seen), 2)
    assert_equal(seen[0], "alpha")
    assert_equal(seen[1], "beta")


def test_copy_is_independent() raises:
    var original = tree([1, 2, 3])
    var duplicate = original.copy()
    duplicate.add(4)
    assert_elements(original, [1, 2, 3])
    assert_elements(duplicate, [1, 2, 3, 4])


# ===-----------------------------------------------------------------------===#
# Randomised cross-check against a reference implementation
# ===-----------------------------------------------------------------------===#


def test_random_add_delete_against_reference() raises:
    """Mirrors every operation into a sorted List and compares the contents."""
    var set = RBTree[Int]()
    var reference = List[Int]()
    var state = 12345

    for step in range(4000):
        # xorshift, so the sequence is deterministic across runs.
        state ^= state << 13
        state &= 0xFFFF_FFFF_FFFF_FFFF
        state ^= state >> 7
        state ^= state << 17
        state &= 0xFFFF_FFFF_FFFF_FFFF
        var value = Int(state % 500)

        var position = 0
        while position < len(reference) and reference[position] < value:
            position += 1
        var present = position < len(reference) and reference[position] == value

        if step % 3 == 2:
            assert_equal(set.delete(value), present)
            if present:
                _ = reference.pop(position)
        else:
            set.add(value)
            if not present:
                reference.insert(position, value)

        assert_equal(len(set), len(reference))
        if step % 500 == 0:
            assert_rb_valid(set)

    assert_elements(set, reference)
    assert_rb_valid(set)
    assert_elements(set, reference)


# ===-----------------------------------------------------------------------===#
# Red-black invariants
# ===-----------------------------------------------------------------------===#


def test_invariants_hold_after_random_inserts() raises:
    var set = RBTree[Int]()
    var state = 0x2545
    for _ in range(2000):
        state = (state * 1103515245 + 12345) & 0x7FFF_FFFF
        set.add(state % 5000)
    assert_rb_valid(set)


def test_invariants_hold_after_ascending_inserts() raises:
    """The case that makes an unbalanced tree degenerate into a list."""
    var set = RBTree[Int]()
    for i in range(2000):
        set.add(i)
    assert_equal(len(set), 2000)
    assert_rb_valid(set)


def test_invariants_hold_after_descending_inserts() raises:
    var set = RBTree[Int]()
    for i in range(2000, 0, -1):
        set.add(i)
    assert_equal(len(set), 2000)
    assert_rb_valid(set)


def test_height_stays_logarithmic() raises:
    """Red-black rules bound the height at 2*log2(n + 1)."""
    var set = RBTree[Int]()
    for i in range(10_000):
        set.add(i)
    var bound = 2 * _bit_width(10_001)
    assert_true(
        set.height() <= bound,
        String("height ", set.height(), " exceeds the bound ", bound),
    )
    # A list would be 10000 deep; the bound here is 28.
    assert_true(set.height() < 30)


def test_invariants_hold_after_deleting_every_element() raises:
    var set = RBTree[Int]()
    for i in range(500):
        set.add(i)
    for i in range(0, 500, 2):
        assert_true(set.delete(i))
        if i % 50 == 0:
            assert_rb_valid(set)
    assert_equal(len(set), 250)
    assert_rb_valid(set)
    for i in range(1, 500, 2):
        assert_true(set.delete(i))
    assert_equal(len(set), 0)
    assert_rb_valid(set)


def test_invariants_hold_when_deleting_in_reverse() raises:
    var set = RBTree[Int]()
    for i in range(300):
        set.add(i)
    for i in range(299, -1, -1):
        assert_true(set.delete(i))
    assert_equal(len(set), 0)
    assert_rb_valid(set)


def test_slots_stay_dense_across_churn() raises:
    """Deleting moves the last node into the gap, so no slot is ever wasted."""
    var set = RBTree[Int]()
    for i in range(200):
        set.add(i)
    for i in range(0, 200, 2):
        _ = set.delete(i)
    assert_equal(set._count, len(set) + 1)
    for i in range(1000, 1100):
        set.add(i)
    assert_equal(set._count, len(set) + 1)
    assert_rb_valid(set)


def test_delete_then_reinsert_keeps_invariants() raises:
    var set = RBTree[Int]()
    for _ in range(20):
        for i in range(50):
            set.add(i)
        for i in range(0, 50, 3):
            _ = set.delete(i)
        assert_rb_valid(set)
    assert_rb_valid(set)


def test_building_from_sorted_is_valid_at_every_size() raises:
    """`_from_sorted` colours the tree directly instead of inserting; check it
    produces a legal red-black tree for every size, not just convenient ones."""
    for size in range(1, 200):
        var elements = List[Int]()
        for i in range(size):
            elements.append(i * 3)
        var left = RBTree[Int](elements)
        var right = RBTree[Int](List[Int]())
        var built = left.union(right)
        assert_equal(len(built), size, String("wrong size for ", size))
        assert_rb_valid(built)
        assert_elements(built, elements)


def _bit_width(n: Int) -> Int:
    var value = n
    var width = 0
    while value > 0:
        value >>= 1
        width += 1
    return width


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
