# mm_rb_tree

[![CI](https://github.com/Mojo-Mania/mm_rb_tree/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_rb_tree/actions/workflows/ci.yml)

A sorted set for [Mojo](https://mojolang.org), backed by a red-black tree.

The storage is the same design as [`mm_fiby_tree`](https://github.com/Mojo-Mania/mm_fiby_tree):
the elements in one owned buffer, every index the tree needs in another divided
into regions, nodes addressed by index rather than by pointer. A whole set is
two allocations and a 40-byte handle. What changes is the balancing — red-black
rules instead of "rebuild the whole tree into level order once it gets too
deep".

That swap has one headline consequence: **no input order degrades it**. Every
insert, lookup and delete is O(log n) worst case, with nothing to rebuild
afterwards.

```mojo
var ordered = RBTree[Int]()
for i in range(10_000):
    ordered.add(i)          # the case that degenerates an unbalanced tree
print(ordered.height())     # 24, against a bound of 2*log2(n+1) = 28
```

## Install

```bash
pixi add --git https://github.com/Mojo-Mania/mm_rb_tree.git mm_rb_tree
```

Needs `preview = ["pixi-build"]` in the consuming workspace and pixi 0.80+.
Or vendor the `mm_rb_tree/` directory and compile with `mojo -I path/to/mm_rb_tree`.

## Usage

```mojo
from mm_rb_tree import RBTree

var set = RBTree[Int]()
set.add(13)
set.add(7)
set.add(13)                    # already present, ignored

print(len(set))                # 2
print(7 in set)                # True
print(set.sorted_elements())   # [7, 13]
print(set.min().value())       # 7

for element in set:            # ascending, by reference, nothing copied
    print(element)

var other = RBTree[Int]([7, 21])
print(set.union(other).sorted_elements())         # [7, 13, 21]
print(set.intersection(other).sorted_elements())  # [7]
print(set.is_disjoint(other))                     # False
```

Any ordered, copyable type works as the element type, and the index width,
growth factor and initial capacity are all tunable:

```mojo
RBTree[String]
RBTree[Int, DType.uint16]          # quarter the link memory, 65535 max
RBTree[Int, DType.uint32, 150]     # grow by half instead of doubling
RBTree[Int](capacity=10_000)       # or skip growing entirely
```

## API

| Member | Meaning |
| --- | --- |
| `add(element)` | Insert; ignored if already present. |
| `delete(element) -> Bool` | Remove; returns whether it was there. |
| `element in set`, `len(set)`, `Bool(set)`, `capacity()` | Membership, size, emptiness, room. |
| `set == other` | Same elements. |
| `min() / max() -> Optional[T]` | Extremes, `None` when empty. |
| `height()` | Longest root-to-leaf path, for checking the balance holds. |
| `for element in set` | Iterate in ascending order, by reference. |
| `sorted_elements() -> List[T]` | Every element, ascending, as a list. |
| `clear()` | Drop everything, keep the storage. |
| `union / intersection / difference / symmetric_difference` | Return a new set. |
| `*_inplace(other)`, `other_difference_inplace(other)` | Same, mutating `self`. |
| `is_subset / is_superset / is_disjoint` | Predicates, short-circuiting. |
| `print_tree(set)` | Free function; prints the shape with colours. |

## Performance

4000 elements, Apple M-series, nanoseconds per operation, release build
(`-D ASSERT=none`, which is what `pixi run bench` passes). Lower is better.

`FibyTree` is the sibling structure this shares its storage with, shown for
comparison; its balanced column is after an explicit `balance()`.

| Operation (`Int`) | RBTree | FibyTree | after `balance()` | stdlib `Set` | Sorted `List` |
| --- | --- | --- | --- | --- | --- |
| build, random input | 17.1 | **15.8** | | 11.3 | 81.5 |
| **build, ascending input** | **26.4** | 120.9 | | 16.1 | 8.0 |
| lookup, present | 12.6 | 16.6 | **9.1** | 1.8 | 11.4 |
| lookup, absent | 11.9 | 12.3 | **8.9** | 2.4 | 10.8 |
| delete | 39.9 | **12.2** | | 2.2 | 115.4 |
| walk in order | 3.0 | **1.4** | | n/a | 0.2 |
| union | 7.2 | **4.8** | | 7.2 | — |
| intersection | 3.1 | **2.7** | | 2.8 | — |
| create + destroy 20000 eight-element sets | 284.8 | **177.6** | | 168.9 | — |

Reading the table:

- **Ascending input is 4.6× faster than the fiby tree** — 26.4 ns against
  120.9 — and that is the whole reason to pick this one. The fiby tree gets
  there by rebuilding itself whenever it notices it has gone too deep, which is
  O(n) each time; red-black rules keep it balanced as it goes, with a couple of
  rotations per insert.
- **Lookups beat an unbalanced fiby tree and lose to a balanced one.** 12.6 ns
  against 16.6 and 9.1. Nothing beats a level-order array for pure lookup — but
  the fiby tree only has that layout until the next insert.
- **Deletes cost about 3×** what the fiby tree's do, 39.9 against 12.2. That
  comparison flatters the fiby tree: its delete only marks a slot dead and
  leaks it until the next `balance()`, while this one rebalances and keeps the
  slots dense, so no compaction pass is ever needed.
- **Walking is slower**, 3.0 against 1.4 ns per element. Both walk in order;
  the fiby tree pushes an explicit stack, and climbing parent links turns out
  to cost more than pushing and popping.
- **Set algebra is at parity with the hash set** (7.2 vs 7.2 on union) because
  merging two ordered sequences hashes nothing, and the result is built in O(n)
  rather than inserted element by element.
- **If you only need membership, use the stdlib `Set`.** It wins that column by
  5×, and this structure is for when order matters.

### Real words

The tables above use generated elements. `corpora/` holds twelve word lists —
Latin, Greek, Hebrew, Arabic, Georgian, Devanagari and CJK scripts, plus a list
of AWS S3 action names — taken from
[compact-dict](https://github.com/mzaks/compact-dict). They matter more to an
ordered set than to most containers: a tree pays for a comparison at every level
of its descent, and real words share prefixes and arrive in orders that
generated input never reproduces. `pixi run bench-corpora` runs them.

Probes are independently allocated strings. Mojo's `String` is copy-on-write, so
probing with the very object that was inserted lets `__eq__` answer on pointer
identity and skip the byte comparison — that measures the copy-on-write, not the
container.

#### Long keys favour a tree over a hash set

| corpus | avg bytes | `RBTree` | `Set` | `SortedList` |
| --- | --- | --- | --- | --- |
| english | 5 | 19.1 | **7.3** | 24.7 |
| hindi | 18 | 31.7 | **8.8** | 39.6 |
| chinese | 464 | **26.4** | 51.5 | 46.1 |
| japanese | 499 | **28.3** | 55.0 | 47.3 |

Nanoseconds per lookup. On ordinary words a hash set wins, as it should: it
hashes once where a tree compares at every level. On the CJK corpora, whose
"words" are whole paragraphs of 400–560 bytes, that reverses — a hash set must
read every byte of the key to hash it, while a comparison usually decides in the
first few. Generated keys of uniform length never show this.

#### Order of arrival does not matter

The S3 action list is mostly alphabetical — a longest ascending run of 64 out of
161, where the natural-language corpora run 4 to 6. A red-black tree rebalances
as it goes, so it barely notices:

| corpus | `RBTree` | `mm_fiby_tree` |
| --- | --- | --- |
| s3_actions, insert | **41.4 ns** | 81.2 ns |
| s3_actions, membership | **24.4 ns** | 50.2 ns |
| s3_actions, vocabulary | **7.3 µs** | 13.1 µs |
| english, insert | 28.3 ns | 27.3 ns |

On randomly ordered words the two are level; on sorted input this one is twice
as fast. That is the trade the two libraries make — see
[mm_fiby_tree](https://github.com/Mojo-Mania/mm_fiby_tree), which is cheaper to
rebuild but degrades on monotonic input.

#### Producing a vocabulary in order

The reason to keep an ordered set at all: corpus in, alphabetical vocabulary
out. Microseconds per corpus.

| corpus | distinct | `RBTree` | `Set` + sort | `SortedList` |
| --- | --- | --- | --- | --- |
| french | 418 | **15.2** | 15.7 | 25.7 |
| s3_actions | 143 | 7.3 | 7.8 | **6.1** |
| hebrew | 231 | **12.4** | 12.5 | 14.5 |
| l33t | 339 | 14.0 | **13.8** | 21.0 |
| english | 192 | 24.3 | **14.2** | 26.2 |

The tree wins where most words are distinct, and loses where they are not:
english is 999 words but only 192 of them, so the hash set absorbs 807 duplicate
inserts cheaply and then sorts a short list.


## Development

```bash
pixi run test     # the test suite (57 tests)
pixi run bench-corpora  # the corpus tables
pixi run bench    # the benchmarks above
pixi run main     # the example
pixi run format   # mojo format
pixi run docs     # docstring check
pixi build        # build the conda package (needs pixi >= 0.80)
```

## License

MIT. See [LICENSE](LICENSE).
