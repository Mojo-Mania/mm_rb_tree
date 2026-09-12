# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`), which is what `pixi run bench` passes.

## 1. Walking is slower than it should be

An in-order walk costs 3.0 ns per element against the fiby tree's 1.4. Both
visit the same nodes in the same order; the fiby tree pushes an explicit stack,
while this one climbs parent links to find each successor. Climbing is
allocation-free and needs no state, which is why it was the obvious choice, but
it evidently costs more than pushing and popping — the climb is a chain of
dependent loads with an unpredictable exit.

Worth measuring a stack-based cursor here too, since the parent links are
already paid for and could simply go unused during a walk.

## 2. Colour could live in the parent link

Colour is one bit and occupies a whole region: four bytes a node with `uint32`
indices, which is a quarter of the link memory. Packing it into the high bit of
the parent link would reclaim that, at the cost of a mask on every parent read
and write, and halving the index range to 2^31 nodes.

The balancing code touches parents constantly, so this is worth measuring
rather than assuming: the mask may cost more than the cache pressure it saves.

## 3. Delete is 3× the fiby tree's

39.9 ns against 12.2. Some of that is inherent — this one rebalances, that one
does not — but some is the swap-remove that keeps slots dense, which writes to
up to three other nodes. An alternative is a free list, at the price of
fragmentation and a compaction pass, which is exactly what this structure was
meant to avoid. Measure before trading it away.

## 4. Smaller items

- **`height()` recurses.** It is a diagnostic, used by tests, but it would
  overflow on a pathological tree — which red-black rules make impossible, so
  this is theoretical. An iterative version would still be tidier.
- **`_from_sorted` builds recursively**, one stack frame per node on the way
  down. Depth is logarithmic, so it is bounded, but an iterative build would
  remove the question.
- **`union` and friends materialise a `List`** before rebuilding a tree. A
  caller that only wants to iterate the result pays for the tree it never uses.
- **No `shrink_to_fit`.** Deleting keeps slots dense but never returns memory.
- **The index-overflow `debug_assert` disappears in release builds.** For
  `uint16` indices a real check is cheap next to an insert.
