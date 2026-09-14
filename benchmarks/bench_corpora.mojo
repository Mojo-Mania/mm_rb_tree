"""Benchmarks RBTree on real words rather than generated ones.

`corpora/` holds twelve word lists -- Latin, Greek, Hebrew, Arabic, Georgian,
Devanagari and CJK scripts, plus a list of AWS S3 action names for long ASCII
identifiers -- taken from github.com/mzaks/compact-dict. Real words matter to an
ordered set more than to most containers: a tree pays for a comparison at every
level of its descent, and comparing two words that share a prefix costs far more
than comparing two `Int`s. Generated fixed-length strings differ in their first
byte and hide that entirely.

The baselines are the same two the main suite uses. `Set` is the stdlib hash
set, fastest for pure membership but unordered. `SortedList` is a `List` kept in
order with binary-search lookup: ordered like a tree, but every insert shifts
the tail.

The last benchmark is the one that justifies an ordered set at all -- take a
corpus and produce its vocabulary in alphabetical order. A tree iterates; a hash
set has to collect and sort.

Nanoseconds per operation unless stated. Lower is better.
"""

from corpora import load, names
from mm_rb_tree import RBTree
from std.benchmark import Unit, keep, run
from std.collections import Set


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


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)


def fmt(value: Float64) -> String:
    var tenths = Int(value * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def pad(text: String, width: Int) -> String:
    var padded = text
    while padded.byte_length() < width:
        padded += " "
    return padded^


def rpad(text: String, width: Int) -> String:
    var padded = text
    while padded.byte_length() < width:
        padded = " " + padded
    return padded^


def header(title: String, unit: String):
    print("")
    print(title)
    print("   corpus          tree      Set   SortedList   ", unit)
    print("   ---------------------------------------------")


def row(name: String, tree: Float64, set: Float64, list: Float64):
    print(
        "  ",
        pad(name, 12),
        rpad(fmt(tree), 7),
        rpad(fmt(set), 8),
        rpad(fmt(list), 10),
    )


def distinct_words(name: StringSlice) raises -> List[String]:
    """The corpus with duplicates removed, in first-seen order."""
    var words = load(name)
    var seen = Set[String]()
    var result = List[String]()
    for i in range(len(words)):
        if words[i] not in seen:
            seen.add(words[i])
            result.append(words[i])
    return result^


def bench_build(corpora: List[String]) raises:
    header("insert every distinct word", "ns per insert")
    for name in corpora:
        var words = distinct_words(name)
        var count = Float64(len(words))

        def tree() raises {imm words}:
            var t = RBTree[String]()
            for i in range(len(words)):
                t.add(words[i])
            keep(len(t))

        def set() raises {imm words}:
            var s = Set[String]()
            for i in range(len(words)):
                s.add(words[i])
            keep(len(s))

        def list() raises {imm words}:
            var l = SortedList[String]()
            for i in range(len(words)):
                l.add(words[i])
            keep(len(l))

        row(
            name,
            measure(tree) / count,
            measure(set) / count,
            measure(list) / count,
        )


def bench_membership(corpora: List[String]) raises:
    header("look up every word, all present", "ns per lookup")
    for name in corpora:
        var words = distinct_words(name)
        var count = Float64(len(words))
        var t = RBTree[String]()
        var s = Set[String]()
        var l = SortedList[String]()
        for i in range(len(words)):
            t.add(words[i])
            s.add(words[i])
            l.add(words[i])

        # Independently allocated probes. Mojo's `String` is copy-on-write, so
        # probing with the very object that was inserted lets `__eq__` answer on
        # pointer identity and skip the byte comparison -- which measures the
        # copy-on-write, not the container.
        var probes = List[String](capacity=len(words))
        for i in range(len(words)):
            probes.append(String(words[i], ""))

        def tree() raises {imm t, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in t:
                    hits += 1
            keep(hits)

        def set() raises {imm s, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in s:
                    hits += 1
            keep(hits)

        def list() raises {imm l, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in l:
                    hits += 1
            keep(hits)

        row(
            name,
            measure(tree) / count,
            measure(set) / count,
            measure(list) / count,
        )


def bench_absent(corpora: List[String]) raises:
    header("membership, probes from another script", "ns per lookup")
    for name in corpora:
        var words = distinct_words(name)
        var probes = load("georgian" if name != "georgian" else "hindi")
        var count = Float64(len(probes))
        var t = RBTree[String]()
        var s = Set[String]()
        var l = SortedList[String]()
        for i in range(len(words)):
            t.add(words[i])
            s.add(words[i])
            l.add(words[i])

        def tree() raises {imm t, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in t:
                    hits += 1
            keep(hits)

        def set() raises {imm s, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in s:
                    hits += 1
            keep(hits)

        def list() raises {imm l, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in l:
                    hits += 1
            keep(hits)

        row(
            name,
            measure(tree) / count,
            measure(set) / count,
            measure(list) / count,
        )


def bench_vocabulary(corpora: List[String]) raises:
    """Corpus in, alphabetical vocabulary out -- the reason to want an order.

    The tree inserts and walks. The hash set inserts, collects and sorts. The
    sorted list is ordered as it goes, paying on every insert instead.
    """
    header("build a corpus's vocabulary, in order", "us per corpus")
    for name in corpora:
        var words = load(name)

        def tree() raises {imm words}:
            var t = RBTree[String]()
            for i in range(len(words)):
                t.add(words[i])
            var out = List[String](capacity=len(t))
            for word in t:
                out.append(word)
            keep(len(out))

        def set() raises {imm words}:
            var s = Set[String]()
            for i in range(len(words)):
                s.add(words[i])
            var out = List[String](capacity=len(s))
            for word in s:
                out.append(word)
            sort(out)
            keep(len(out))

        def list() raises {imm words}:
            var l = SortedList[String]()
            for i in range(len(words)):
                l.add(words[i])
            keep(len(l))

        row(
            name,
            measure(tree) / 1000.0,
            measure(set) / 1000.0,
            measure(list) / 1000.0,
        )


def main() raises:
    var corpora = names()
    print("corpora, distinct words only")
    for name in corpora:
        var words = distinct_words(name)
        var bytes = 0
        for i in range(len(words)):
            bytes += words[i].byte_length()
        print(
            "  ",
            pad(name, 12),
            rpad(String(len(words)), 5),
            "words,",
            bytes // len(words),
            "bytes each",
        )

    bench_build(corpora)
    bench_membership(corpora)
    bench_absent(corpora)
    bench_vocabulary(corpora)
