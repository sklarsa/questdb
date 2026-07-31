"""Unit tests for generate.py (the dynamic pipeline generator).

Run: cd .buildkite && python3 -m unittest test_generate -v
Pure-logic tests only - no Buildkite API, no network.
"""
import os
import tempfile
import unittest

import generate


class TestBinPack(unittest.TestCase):
    def test_bin_pack_balances_by_time(self):
        classes = [f"C{i}" for i in range(8)]
        timings = {"C0": 100, "C1": 90, "C2": 80, "C3": 70,
                   "C4": 60, "C5": 50, "C6": 40, "C7": 30}
        shards = generate.bin_pack(classes, timings, 4)
        loads = [sum(timings[c] for c in s) for s in shards]
        # LPT greedy keeps shards within roughly one item's weight of each other.
        self.assertLessEqual(max(loads) - min(loads), 30)
        # No class lost or duplicated.
        self.assertEqual(sorted(c for s in shards for c in s), sorted(classes))

    def test_unknown_class_gets_median(self):
        classes = ["A", "B", "NEW"]
        timings = {"A": 10, "B": 30}  # NEW unknown -> median of known
        shards = generate.bin_pack(classes, timings, 2)
        self.assertEqual(sorted(c for s in shards for c in s), ["A", "B", "NEW"])
        # NEW must be weighted (median), not collapsed to 0 onto an empty shard.
        loads = [sum(timings.get(c, 30) for c in s) for s in shards]
        self.assertGreater(min(loads), 0)

    def test_bin_pack_empty(self):
        self.assertEqual(generate.bin_pack([], {}, 4), [[], [], [], []])


class TestLoadTimings(unittest.TestCase):
    def test_load_timings_sums_time(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "TEST-io.questdb.test.Foo.xml")
        with open(p, "w") as f:
            f.write('<testsuite name="io.questdb.test.Foo" time="12.5"></testsuite>')
        t = generate.load_timings([p])
        self.assertEqual(t["io.questdb.test.Foo"], 12.5)

    def test_load_timings_skips_malformed(self):
        d = tempfile.mkdtemp()
        good = os.path.join(d, "TEST-Good.xml")
        bad = os.path.join(d, "TEST-Bad.xml")
        with open(good, "w") as f:
            f.write('<testsuite name="Good" time="1.0"/>')
        with open(bad, "w") as f:
            f.write('<<< not xml >>>')
        t = generate.load_timings([good, bad])
        self.assertEqual(t, {"Good": 1.0})

    def test_load_timings_duplicate_sums(self):
        d = tempfile.mkdtemp()
        p1 = os.path.join(d, "a.xml")
        p2 = os.path.join(d, "b.xml")
        with open(p1, "w") as f:
            f.write('<testsuite name="Dup" time="1.5"/>')
        with open(p2, "w") as f:
            f.write('<testsuite name="Dup" time="2.5"/>')
        t = generate.load_timings([p1, p2])
        self.assertEqual(t["Dup"], 4.0)


class TestSelectShards(unittest.TestCase):
    def test_docs_only_change_selects_no_test_shards(self):
        self.assertEqual(generate.select_shards({"docs/x.md", "README.md"}), set())

    def test_core_change_selects_test_shards(self):
        s = generate.select_shards({"core/src/main/java/io/questdb/cairo/X.java"})
        self.assertTrue(len(s) > 0)

    def test_compat_change_selects_test_shards(self):
        s = generate.select_shards({"compat/src/test/java/io/questdb/compat/Y.java"})
        self.assertTrue(len(s) > 0)


class TestRenderAndMain(unittest.TestCase):
    def test_render_pipeline_is_valid_yaml_ish(self):
        # render must emit a steps: block referencing each shard.
        shards = [["io.questdb.test.griffin.ATest"], ["io.questdb.test.cairo.BTest"]]
        out = generate.render_pipeline(shards)
        self.assertIn("steps:", out)
        self.assertIn("test.include", out)

    def test_render_empty_shards_still_valid(self):
        out = generate.render_pipeline([])
        self.assertIn("steps:", out)

    def test_class_to_glob(self):
        # a class FQN maps to a surefire include for exactly that class
        g = generate.class_to_include("io.questdb.test.griffin.AddIndexTest")
        self.assertIn("AddIndexTest", g)


if __name__ == "__main__":
    unittest.main()
