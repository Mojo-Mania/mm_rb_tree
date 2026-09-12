# Design

## Why another tree

`mm_fiby_tree` and this one are the same data structure with different
balancing. Both store a binary search tree in owned buffers addressed by index;
both give ordered iteration, set algebra, and O(log n) membership when they are
balanced. The difference is what happens when they are not.

The fiby tree does nothing until the tree gets deeper than `(log2 n)²`, then
rebuilds the whole thing into level order. That is very cheap for random input,
which rarely triggers it, and gives the fastest lookups in the family while it
lasts, because a level-order array needs no child pointers at all. It is
quadratic for ascending input, and its `delete` leaks a slot until the next
rebuild.

A red-black tree pays a little on every insert instead — a recolour, sometimes
a rotation or two — and in exchange has no bad input, no rebuild pass, and a
delete that keeps the storage dense. Pick this one when the input order is not
yours to choose, or when deletes are frequent.

## Storage

Shared with `mm_fiby_tree`, and described there in more detail. Briefly:

- The elements live in one buffer, every index in another divided into regions
  of `_capacity` entries: left child, right child, parent, colour.
- Growth relocates the elements with one bulk move and each link region with
  one `memcpy`, behind an `@always_inline` check and a `@no_inline` grow.
- `capacity` is a constructor argument, `growth_percent` a compile-time
  parameter.

Two things differ from the fiby tree:

**Slot 0 is a sentinel.** Red-black deletion is written in terms of a NIL node
that has a colour and, briefly, a parent — the fixup walks up from it. Giving
NIL a real slot lets the textbook algorithm transcribe directly, instead of
being rewritten around a self-pointer convention that cannot represent "the
parent of nothing". Real nodes start at index 1, and `len()` is `_count - 1`.

**There is no free list.** Deleting moves the last node into the freed slot and
fixes the handful of links that pointed at it, so slots 1 to `_count - 1` are
always exactly the live nodes. That costs a few pointer writes per delete and
means fragmentation never happens, so unlike the fiby tree there is nothing to
compact and no `balance()` to remember to call.

## Colour storage

Colour is one bit, and it occupies a whole `Index` region — four bytes a node
with the default `uint32`. Packing it into the high bit of the parent link
would save that, at the cost of a mask on every parent read and write, and one
bit of index range. It is recorded in `improvements.md` rather than done,
because the balancing code is where the subtle bugs live and it was worth
getting that right against a plain representation first.

## Building from a sorted list

Set operations merge two ordered walks and then have to turn the result back
into a tree. Inserting the elements one at a time would be O(n log n) and a
rotation storm; a sorted list already describes the shape.

`_from_sorted` splits at the middle, recurses, and colours red exactly the
nodes at depth `floor(log2(n + 1))` — the level past the perfect prefix. Every
root-to-leaf path then crosses the same number of black nodes, and the red
nodes are all leaves, so no red has a red child. When `n + 1` is a power of two
the tree is perfect and nothing is red.

That took union from 24.4 to 7.2 ns per element. A test builds from sorted
lists of every size from 1 to 199 and checks the red-black invariants on each,
because an off-by-one in the colouring rule would only show at particular
sizes.

## Testing

`assert_rb_valid` checks, after the operations that can break them:

1. the root is black
2. no red node has a red child
3. every root-to-leaf path crosses the same number of black nodes
4. the in-order walk strictly increases and visits `len` elements
5. every child agrees with its parent
6. slots stay dense — `_count == len + 1`

It runs after ascending, descending and random insert runs, after deleting
every element in both directions, and every 500 steps of a 4000-operation
randomised add/delete sequence that is cross-checked against a sorted `List`.
