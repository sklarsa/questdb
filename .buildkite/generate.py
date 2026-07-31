#!/usr/bin/env python3
"""Dynamic Buildkite pipeline generator for QuestDB.

Two responsibilities, sharing one bootstrap mechanism:
  1. Change detection - diff against master; if only docs/CI changed, skip the
     (expensive) test shards entirely.
  2. Weighted sharding - bin-pack test classes into N roughly-equal-WALL-CLOCK
     shards using per-class times from the last green build's surefire XML
     (griffin is 57% of classes but ~1/3 the wall time of cairo, so count-based
     splitting is inverted; see the 2026-07-31 design doc).

The pure functions (load_timings / bin_pack / select_shards / render_pipeline)
are unit-tested in test_generate.py. main() wires them to the Buildkite REST API
and, on ANY error, prints the committed static pipeline and exits 0 so a
generator bug can never fail the build.

Stdlib only. Python 3.
"""
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

N_SHARDS = 4  # test shards; tune from observed wall-clock balance.
STATIC_FALLBACK = os.path.join(os.path.dirname(__file__), "pipeline.static.yaml")


def load_timings(xml_paths):
    """Map test-class FQN -> summed wall-clock seconds from surefire XML.

    Skips unparseable files rather than raising - a truncated artifact must not
    sink the whole generation. Duplicate suite entries (a class re-run across
    forks) sum, matching total observed cost.
    """
    out = {}
    for p in xml_paths:
        try:
            root = ET.parse(p).getroot()
        except (ET.ParseError, OSError):
            continue
        name = root.get("name")
        t = root.get("time")
        if name and t:
            try:
                out[name] = out.get(name, 0.0) + float(t)
            except ValueError:
                continue
    return out


def bin_pack(classes, timings, n_shards):
    """Greedy longest-processing-time-first bin-packing into n_shards lists.

    Unknown classes (no timing yet) are weighted at the median of known times so
    a brand-new class is placed reasonably rather than treated as free.
    """
    shards = [[] for _ in range(n_shards)]
    if not classes:
        return shards
    known = sorted(t for t in timings.values() if t > 0)
    median = known[len(known) // 2] if known else 1.0
    weighted = sorted(classes, key=lambda c: timings.get(c, median), reverse=True)
    loads = [0.0] * n_shards
    for c in weighted:
        i = loads.index(min(loads))
        shards[i].append(c)
        loads[i] += timings.get(c, median)
    return shards


def changed_paths(base_ref="origin/master"):
    """Files changed vs base_ref (three-dot: since the merge-base)."""
    try:
        out = subprocess.run(
            ["git", "diff", "--name-only", f"{base_ref}...HEAD"],
            capture_output=True, text=True, check=False,
        ).stdout
    except OSError:
        return set()
    return {ln for ln in out.splitlines() if ln.strip()}


def select_shards(changed):
    """Decide whether the test shards must run for this diff.

    Docs/CI-only diffs skip the test shards; any core/ or compat/ source change
    runs them. Shard-level granularity for now (class-level pruning is a later
    refinement). Returns a set - empty means "skip test shards".
    """
    src = {
        p for p in changed
        if (p.startswith("core/") or p.startswith("compat/") or p.startswith("utils/"))
        and not p.endswith(".md")
    }
    return {"tests"} if src else set()


def class_to_include(fqn):
    """Surefire -Dtest.include glob matching exactly one class by simple name."""
    simple = fqn.rsplit(".", 1)[-1]
    return f"**/{simple}.java"


def _discover_test_classes():
    """Enumerate test-class FQNs from the source tree (fallback when no timings).

    Walks core/src/test for *Test.java and derives the FQN from the path.
    """
    classes = []
    root = os.path.join("core", "src", "test", "java")
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith("Test.java"):
                rel = os.path.relpath(os.path.join(dirpath, f), root)
                fqn = rel[:-len(".java")].replace(os.sep, ".")
                classes.append(fqn)
    return classes


def render_pipeline(shards):
    """Emit a Buildkite pipeline YAML string for the weighted test shards.

    Always includes the always-run lint leg. Each shard runs its class list via
    a comma-joined -Dtest.include. Emits a valid (if minimal) steps: block even
    for an empty shard list.
    """
    lines = ["steps:"]
    lines += [
        '  - label: ":lint-roller: lint"',
        "    agents: { queue: linux-small }",
        "    command: |",
        "      source .buildkite/prelude.sh",
        "      python3 find_unterminated_logs.py core/src --exclude=LogParanoiaTest.java",
    ]
    for i, shard in enumerate(s for s in shards if s):
        includes = ",".join(class_to_include(c) for c in shard)
        lines += [
            f'  - label: ":coffee: test: shard-{i}"',
            "    agents: { queue: linux-large }",
            "    artifact_paths:",
            '      - "core/target/surefire-reports/**/*.xml"',
            "    command: |",
            "      source .buildkite/prelude.sh",
            f"      mvn $MVN_COMMON clean test -Dtest.include='{includes}'",
        ]
    return "\n".join(lines) + "\n"


def _emit_static_fallback():
    """Print the committed static pipeline verbatim (used on any generator error)."""
    try:
        with open(STATIC_FALLBACK) as f:
            sys.stdout.write(f.read())
    except OSError:
        # Absolute last resort: a trivial always-valid pipeline.
        sys.stdout.write('steps:\n  - command: "echo generator-and-fallback-failed; exit 1"\n')


def main():
    try:
        changed = changed_paths()
        if changed and not select_shards(changed):
            # Docs/CI-only change: emit a no-test pipeline (lint only).
            sys.stdout.write(render_pipeline([]))
            return
        # Timings come from surefire artifacts fetched by the bootstrap into
        # ./surefire-timings/ (see the bootstrap step). Absent -> empty -> the
        # median fallback in bin_pack still produces balanced shards by count.
        timing_dir = os.environ.get("QDB_TIMING_DIR", "surefire-timings")
        xmls = []
        if os.path.isdir(timing_dir):
            for dp, _d, fs in os.walk(timing_dir):
                xmls += [os.path.join(dp, f) for f in fs if f.endswith(".xml")]
        timings = load_timings(xmls)
        classes = _discover_test_classes()
        shards = bin_pack(classes, timings, N_SHARDS)
        sys.stdout.write(render_pipeline(shards))
    except Exception as e:  # never fail the build on a generator bug
        sys.stderr.write(f"generate.py failed ({e!r}); emitting static fallback\n")
        _emit_static_fallback()


if __name__ == "__main__":
    main()
