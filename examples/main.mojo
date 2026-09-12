"""A short tour of `RBTree`."""

from mm_rb_tree import RBTree, print_tree


def main() raises:
    var set = RBTree[String]()
    for name in ["pear", "apple", "fig", "apple", "date"]:
        set.add(name)

    print("count:", len(set), "(apple was added twice)")
    print("has fig:", String("fig") in set)
    print("smallest:", set.min().value(), "largest:", set.max().value())

    print("\nin order:")
    for name in set:
        print(" ", name)

    print("\nshape, with colours:")
    print_tree(set)

    # Ascending input is the case that degenerates an unbalanced tree. Here it
    # costs nothing: the height stays logarithmic without any rebuild pass.
    var ordered = RBTree[Int](capacity=10_000)
    for i in range(10_000):
        ordered.add(i)
    print("\n10000 ascending inserts -> height", ordered.height())

    var primes = RBTree[Int]([2, 3, 5, 7, 11])
    var odds = RBTree[Int]([1, 3, 5, 7, 9, 11])
    print("\nprimes & odds:", primes.intersection(odds).sorted_elements())
    print("primes - odds:", primes.difference(odds).sorted_elements())
    print("primes ^ odds:", primes.symmetric_difference(odds).sorted_elements())
    print("odds superset of {3, 5}:", odds.is_superset(RBTree[Int]([3, 5])))
