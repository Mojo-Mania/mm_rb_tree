"""Benchmarks `RBTree` against two alternatives with the same job.

Baselines:

- `Set[T]` -- the stdlib hash set. Fastest for pure membership work, but
  unordered, so it cannot answer "give me the elements in order" without an
  extra sort.
- `SortedList[T]` -- a `List[T]` kept in sorted order, with binary-search
  lookup. The other obvious way to get an ordered set: lookups are as cheap as
  a tree's, but every insert shifts the tail of the array.

Every benchmark runs over both `Int` and `String` elements. Strings matter
because a tree pays for a comparison at every level of the descent, while a
hash set hashes the key once -- and comparing strings that share a long prefix
costs far more than comparing two `Int`s.

Every number printed is nanoseconds for one operation (total time / element
count). Lower is better. The input comes from a fixed seed, so runs are
comparable.
"""

from mm_rb_tree import RBTree
from std.benchmark import Unit, keep, run
from std.collections import Set


comptime SIZE = 4_000
"""Elements per container. Small enough to keep the suite quick."""

comptime Element = Comparable & Copyable & Deinitable & Hashable
"""What a benchmarked element type has to provide: ordering for `RBTree`,
hashing for `Set`."""


# ===-----------------------------------------------------------------------===#
# Deterministic input
# ===-----------------------------------------------------------------------===#


struct Rng(Copyable, Movable):
    """A xorshift64 generator, so every run sees the same sequence."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Int:
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return Int(self.state & 0x7FFF_FFFF)


comptime _DEFAULT_SEED: UInt64 = 0x2545_F491_4F6C_DD1D
comptime _ALPHABET: StaticString = "abcdefghijklmnopqrstuvwxyz0123456789"


def random_ints(
    count: Int, seed: UInt64 = _DEFAULT_SEED, *, odd: Bool = False
) -> List[Int]:
    """Builds `count` random values, all even or all odd.

    Absent-probe lists have to interleave with the stored elements: probing for
    a key that is smaller than everything only ever walks the left spine, which
    is not what a miss normally costs. Storing evens and probing odds keeps
    every probe inside the key range and guaranteed absent.
    """
    var rng = Rng(seed)
    var result = List[Int](capacity=count)
    var offset = 1 if odd else 0
    for _ in range(count):
        result.append((rng.next() % (count * 4)) * 2 + offset)
    return result^


def ordered_ints(count: Int) -> List[Int]:
    var result = List[Int](capacity=count)
    for i in range(count):
        result.append(i * 2)
    return result^


def random_strings(
    count: Int,
    prefix: StaticString = "",
    length: Int = 12,
    seed: UInt64 = _DEFAULT_SEED,
) -> List[String]:
    """Builds `count` strings of `prefix` plus `length` random characters."""
    var rng = Rng(seed)
    var result = List[String](capacity=count)
    for _ in range(count):
        var value = String(prefix)
        for _ in range(length):
            value += _ALPHABET[byte=rng.next() % 36]
        result.append(value^)
    return result^


def ordered_strings(count: Int, prefix: StaticString = "") -> List[String]:
    """Builds `count` ascending strings, zero padded so they sort as written."""
    var result = List[String](capacity=count)
    for i in range(count):
        var digits = String(i)
        var padded = String(prefix)
        for _ in range(10 - digits.byte_length()):
            padded += "0"
        padded += digits
        result.append(padded^)
    return result^


def shuffled[
    T: Copyable & Deinitable
](values: List[T], seed: UInt64 = 0x1234_5678_9ABC_DEF0) -> List[T]:
    """Fisher-Yates shuffle, so probe order is independent of insertion order.

    Parameters:
        T: The element type.

    Args:
        values: The list to shuffle.
        seed: The generator seed.

    Returns:
        A shuffled copy.
    """
    var result = values.copy()
    var rng = Rng(seed)
    for i in range(len(result) - 1, 0, -1):
        result.swap_elements(i, rng.next() % (i + 1))
    return result^


# ===-----------------------------------------------------------------------===#
# Sorted-array baseline
# ===-----------------------------------------------------------------------===#


struct SortedList[T: Comparable & Copyable & Deinitable](
    Copyable, Movable, Sized
):
    """A sorted `List` used as a set: binary-search lookup, shifting insert.

    Parameters:
        T: The element type.
    """

    var data: List[Self.T]

    def __init__(out self):
        self.data = []

    def __len__(self) -> Int:
        return len(self.data)

    @always_inline
    def _lower_bound(self, value: Self.T) -> Int:
        var low = 0
        var high = len(self.data)
        while low < high:
            var mid = (low + high) >> 1
            if self.data[mid] < value:
                low = mid + 1
            else:
                high = mid
        return low

    def add(mut self, value: Self.T):
        var index = self._lower_bound(value)
        if index < len(self.data) and self.data[index] == value:
            return
        self.data.insert(index, value.copy())

    def __contains__(self, value: Self.T) -> Bool:
        var index = self._lower_bound(value)
        return index < len(self.data) and self.data[index] == value

    def delete(mut self, value: Self.T) -> Bool:
        var index = self._lower_bound(value)
        if index < len(self.data) and self.data[index] == value:
            _ = self.data.pop(index)
            return True
        return False


# ===-----------------------------------------------------------------------===#
# Reporting
# ===-----------------------------------------------------------------------===#


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    """Times `f`, capped so the whole suite stays quick."""
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)


def fmt(nanos: Float64) -> String:
    """Formats nanoseconds with one decimal place."""
    var tenths = Int(nanos * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def header(title: String):
    print("")
    print(title)
    print("  container            ns/op")
    print("  ---------------------------")


def report(name: String, nanos: Float64):
    var padded = name
    while padded.byte_length() < 20:
        padded += " "
    print("  ", padded, fmt(nanos))


def per_op(total_ns: Float64, operations: Int) -> Float64:
    return total_ns / Float64(operations)


# ===-----------------------------------------------------------------------===#
# Build
# ===-----------------------------------------------------------------------===#


def bench_build[T: Element](title: String, values: List[T]) raises:
    header(title)
    var count = len(values)

    def build_tree() raises {imm values}:
        var tree = RBTree[T]()
        for value in values:
            tree.add(value)
        keep(len(tree))

    def build_set() raises {imm values}:
        var set = Set[T]()
        for value in values:
            set.add(value.copy())
        keep(len(set))

    def build_list() raises {imm values}:
        var list = SortedList[T]()
        for value in values:
            list.add(value)
        keep(len(list))

    report("RBTree", per_op(measure(build_tree), count))
    report("Set", per_op(measure(build_set), count))
    report("SortedList", per_op(measure(build_list), count))


# ===-----------------------------------------------------------------------===#
# Lookup
# ===-----------------------------------------------------------------------===#


def bench_contains[
    T: Element
](title: String, values: List[T], unordered_probes: List[T]) raises:
    header(title)
    # Probing in insertion order would favour the tree whose nodes are stored
    # in that same order, so the probe sequence is shuffled.
    var probes = shuffled(unordered_probes)
    var count = len(probes)

    var tree = RBTree[T]()
    var set = Set[T]()
    var list = SortedList[T]()
    for value in values:
        tree.add(value)
        set.add(value.copy())
        list.add(value)

    def probe_tree() raises {imm tree, imm probes}:
        var hits = 0
        for probe in probes:
            if probe in tree:
                hits += 1
        keep(hits)

    def probe_set() raises {imm set, imm probes}:
        var hits = 0
        for probe in probes:
            if probe in set:
                hits += 1
        keep(hits)

    def probe_list() raises {imm list, imm probes}:
        var hits = 0
        for probe in probes:
            if probe in list:
                hits += 1
        keep(hits)

    report("RBTree", per_op(measure(probe_tree), count))
    report("Set", per_op(measure(probe_set), count))
    report("SortedList", per_op(measure(probe_list), count))


# ===-----------------------------------------------------------------------===#
# Delete
# ===-----------------------------------------------------------------------===#


def bench_delete[T: Element](values: List[T]) raises:
    """Times deletion as (build + delete) minus (build).

    The container cannot simply be captured mutably and deleted from: a
    `RBTree` never reuses the slot freed by `delete`, so repeated benchmark
    iterations would grow it without bound and measure something else entirely.
    Rebuilding inside the closure keeps every iteration identical.
    """
    header("delete half the elements (per delete, build time subtracted)")
    var victims = List[T](capacity=len(values) // 2)
    for i in range(0, len(values), 2):
        victims.append(values[i].copy())
    var count = len(victims)

    def build_tree() raises {imm values}:
        var tree = RBTree[T]()
        for value in values:
            tree.add(value)
        keep(len(tree))

    def build_and_delete_tree() raises {imm values, imm victims}:
        var tree = RBTree[T]()
        for value in values:
            tree.add(value)
        for victim in victims:
            _ = tree.delete(victim)
        keep(len(tree))

    def build_set() raises {imm values}:
        var set = Set[T]()
        for value in values:
            set.add(value.copy())
        keep(len(set))

    def build_and_delete_set() raises {imm values, imm victims}:
        var set = Set[T]()
        for value in values:
            set.add(value.copy())
        for victim in victims:
            set.discard(victim)
        keep(len(set))

    def build_list() raises {imm values}:
        var list = SortedList[T]()
        for value in values:
            list.add(value)
        keep(len(list))

    def build_and_delete_list() raises {imm values, imm victims}:
        var list = SortedList[T]()
        for value in values:
            list.add(value)
        for victim in victims:
            _ = list.delete(victim)
        keep(len(list))

    report(
        "RBTree",
        per_op(measure(build_and_delete_tree) - measure(build_tree), count),
    )
    report(
        "Set", per_op(measure(build_and_delete_set) - measure(build_set), count)
    )
    report(
        "SortedList",
        per_op(measure(build_and_delete_list) - measure(build_list), count),
    )


# ===-----------------------------------------------------------------------===#
# Ordered output
# ===-----------------------------------------------------------------------===#


def bench_sorted_output[T: Element](values: List[T]) raises:
    header("touch every element in order (per element)")

    var tree = RBTree[T]()
    var list = SortedList[T]()
    for value in values:
        tree.add(value)
        list.add(value)
    var count = len(tree)

    def iterate_tree() raises {imm tree}:
        var seen = 0
        for element in tree:
            keep(element)
            seen += 1
        keep(seen)

    def collect_tree() raises {imm tree}:
        var sorted = tree.sorted_elements()
        for element in sorted:
            keep(element)
        keep(len(sorted))

    def iterate_list() raises {imm list}:
        var seen = 0
        for element in list.data:
            keep(element)
            seen += 1
        keep(seen)

    report("RBTree for-in", per_op(measure(iterate_tree), count))
    report("RBTree collected", per_op(measure(collect_tree), count))
    report("SortedList", per_op(measure(iterate_list), count))
    print("   Set                  n/a -- unordered, needs a sort first")


# ===-----------------------------------------------------------------------===#
# Set algebra
# ===-----------------------------------------------------------------------===#


def bench_set_ops[
    T: Element
](left_values: List[T], right_values: List[T]) raises:
    var left_tree = RBTree[T]()
    var right_tree = RBTree[T]()
    var left_set = Set[T]()
    var right_set = Set[T]()
    for value in left_values:
        left_tree.add(value)
        left_set.add(value.copy())
    for value in right_values:
        right_tree.add(value)
        right_set.add(value.copy())
    var count = len(left_tree) + len(right_tree)

    header("union (per element of both inputs)")

    def union_tree() raises {imm left_tree, imm right_tree}:
        keep(len(left_tree.union(right_tree)))

    def union_set() raises {imm left_set, imm right_set}:
        keep(len(left_set.union(right_set)))

    report("RBTree", per_op(measure(union_tree), count))
    report("Set", per_op(measure(union_set), count))

    header("intersection (per element of both inputs)")

    def intersect_tree() raises {imm left_tree, imm right_tree}:
        keep(len(left_tree.intersection(right_tree)))

    def intersect_set() raises {imm left_set, imm right_set}:
        keep(len(left_set.intersection(right_set)))

    report("RBTree", per_op(measure(intersect_tree), count))
    report("Set", per_op(measure(intersect_set), count))


# ===-----------------------------------------------------------------------===#
# Suites
# ===-----------------------------------------------------------------------===#


def bench_many_small_sets() raises:
    """Create and destroy many small sets.

    A set's fixed cost -- one allocation per internal buffer -- is invisible
    when one set holds 4000 elements and dominant when you hold thousands of
    eight-element sets.
    """
    comptime SETS = 20_000
    comptime ELEMENTS = 8
    header(String("create and destroy ", SETS, " sets of ", ELEMENTS))

    def tree() raises:
        var total = 0
        for _ in range(SETS):
            var set = RBTree[Int]()
            for i in range(ELEMENTS):
                set.add(i)
            total += len(set)
        keep(total)

    def hash_set() raises:
        var total = 0
        for _ in range(SETS):
            var set = Set[Int]()
            for i in range(ELEMENTS):
                set.add(i)
            total += len(set)
        keep(total)

    report("RBTree", per_op(measure(tree), SETS))
    report("Set", per_op(measure(hash_set), SETS))
    print("   (per set, not per element)")


def run_suite[
    T: Element
](
    label: String,
    random: List[T],
    ordered: List[T],
    misses: List[T],
    other: List[T],
) raises:
    print("")
    print("=" * 60)
    print("==", label)
    print("=" * 60)

    bench_build("build from random input (per insert)", random)
    bench_build("build from ascending input (per insert)", ordered)
    bench_contains("lookup, every probe present (per lookup)", random, random)
    bench_contains("lookup, no probe present (per lookup)", random, misses)
    bench_delete(random)
    bench_sorted_output(random)
    bench_set_ops(random, other)


def main() raises:
    print("RBTree benchmarks --", SIZE, "elements, ns per operation")

    bench_many_small_sets()

    run_suite(
        "Int elements",
        random_ints(SIZE),
        ordered_ints(SIZE),
        random_ints(SIZE, seed=0xDEAD_BEEF_CAFE_F00D, odd=True),
        random_ints(SIZE, seed=0x9E37_79B9_7F4A_7C15),
    )

    # Absent probes are drawn from the same generator with a different seed, so
    # they interleave with the stored keys; a 12-character random suffix makes
    # a collision vanishingly unlikely.
    run_suite(
        "String elements, 12 random characters",
        random_strings(SIZE),
        ordered_strings(SIZE),
        random_strings(SIZE, seed=0xDEAD_BEEF_CAFE_F00D),
        random_strings(SIZE, seed=0x9E37_79B9_7F4A_7C15),
    )

    # Same strings behind a shared 40-character prefix, so every comparison has
    # to scan the prefix before it can decide. Hashing pays for the prefix once
    # per lookup; a tree pays for it at every level of the descent.
    comptime PREFIX: StaticString = "urn:example:benchmark:shared:prefix:aaaa"
    run_suite(
        "String elements behind a 40-character shared prefix",
        random_strings(SIZE, prefix=PREFIX),
        ordered_strings(SIZE, prefix=PREFIX),
        random_strings(SIZE, prefix=PREFIX, seed=0xDEAD_BEEF_CAFE_F00D),
        random_strings(SIZE, prefix=PREFIX, seed=0x9E37_79B9_7F4A_7C15),
    )
