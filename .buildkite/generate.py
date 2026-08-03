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
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

N_SHARDS = 4  # test shards; tune from observed wall-clock balance.
STATIC_FALLBACK = os.path.join(os.path.dirname(__file__), "pipeline.static.yaml")
# Committed per-class timings snapshot, refreshed from a green build. This is the
# rate-limit-proof primary source: Buildkite's per-user REST budget (50/window)
# makes a live per-artifact download of a whole green build's surefire XMLs
# impractical, so the generator reads this file when no live timings are present.
COMMITTED_TIMINGS = os.path.join(os.path.dirname(__file__), "timings.json")
# The three static count-based test legs (griffin/cairo/other), as a header-less
# fragment. Used as the --shards-only fallback: if shard generation fails, the
# bootstrap still gets the original test coverage without duplicating the
# non-test legs it already emitted.
STATIC_TEST_LEGS = os.path.join(os.path.dirname(__file__), "pipeline.testlegs.yaml")


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


def load_committed_timings(path=COMMITTED_TIMINGS):
    """Map test-class FQN -> wall-clock seconds from the committed snapshot.

    Best-effort: a missing or malformed snapshot yields an empty map (the
    generator then falls back to bin_pack's median weighting), never an error.
    """
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    raw = doc.get("timings", {}) if isinstance(doc, dict) else {}
    out = {}
    for k, v in raw.items():
        try:
            out[k] = float(v)
        except (TypeError, ValueError):
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


# Classes the static pipeline deliberately excludes and the generator must too.
# ServerMainTest.testServerUpgradeDoesNotOverrideWebConsoleConfig needs the
# bundled web console (-P build-web-console), which these test legs do not build;
# it errors otherwise. The static 'other' leg excludes it for exactly this reason
# (see the 2026-07-29 smoke-test design). Without this the generator would place
# ServerMainTest in a shard and that shard would fail on 1 of 10004 tests.
EXCLUDED_CLASSES = {"io.questdb.test.ServerMainTest"}


def _discover_test_classes():
    """Enumerate test-class FQNs from the source tree (fallback when no timings).

    Walks core/src/test for *Test.java and derives the FQN from the path, minus
    the web-console-dependent classes the static pipeline also excludes.
    """
    classes = []
    root = os.path.join("core", "src", "test", "java")
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f.endswith("Test.java"):
                rel = os.path.relpath(os.path.join(dirpath, f), root)
                fqn = rel[:-len(".java")].replace(os.sep, ".")
                if fqn not in EXCLUDED_CLASSES:
                    classes.append(fqn)
    return classes


def render_shard_steps(shards):
    """Emit ONLY the weighted test-shard step entries (no `steps:` header).

    These replace the three static `test: griffin/cairo/other` legs. Kept
    header-less so the bootstrap can splice them under the static pipeline's
    non-test legs (coverage, docker, macos, compat, ...) rather than dropping
    them -- render_pipeline() would emit a standalone lint+shards pipeline and
    lose every other leg.
    """
    lines = []
    for i, shard in enumerate(s for s in shards if s):
        includes = ",".join(class_to_include(c) for c in shard)
        lines += [
            f'  - label: ":coffee: test: shard-{i}"',
            f"    key: test-shard-{i}",
            "    agents: { queue: linux-large }",
            "    artifact_paths:",
            '      - "core/target/surefire-reports/**/*.xml"',
            "    cache:",
            "      paths:",
            '        - "~/.m2/repository"',
            '      name: "maven"',
            "    command: |",
            "      PRELUDE_NEED_CLIENT=1 source .buildkite/prelude.sh",
            f"      mvn $MVN_COMMON clean test -Dtest.include='{includes}'",
        ]
    return "\n".join(lines) + ("\n" if lines else "")


def render_pipeline(shards):
    """Emit a standalone Buildkite pipeline YAML for the weighted test shards.

    Always includes the always-run lint leg. This is the proof-of-path /
    smoke-test shape (lint + shards only); the production wiring uses
    render_shard_steps() spliced under the full static pipeline instead. Emits a
    valid (if minimal) steps: block even for an empty shard list.
    """
    lines = ["steps:"]
    lines += [
        '  - label: ":lint-roller: lint"',
        "    agents: { queue: linux-small }",
        "    command: |",
        "      source .buildkite/prelude.sh",
        "      python3 find_unterminated_logs.py core/src --exclude=LogParanoiaTest.java",
    ]
    shard_steps = render_shard_steps(shards)
    if shard_steps:
        lines.append(shard_steps.rstrip("\n"))
    return "\n".join(lines) + "\n"


def _emit_static_fallback():
    """Print the committed static pipeline verbatim (used on any generator error)."""
    try:
        with open(STATIC_FALLBACK) as f:
            sys.stdout.write(f.read())
    except OSError:
        # Absolute last resort: a trivial always-valid pipeline.
        sys.stdout.write('steps:\n  - command: "echo generator-and-fallback-failed; exit 1"\n')


def _compute_shards():
    """Load the best available timings and bin-pack the discovered classes."""
    # Timings source, in order of preference:
    #  1. Live surefire XMLs the bootstrap fetched into ./surefire-timings/
    #     (freshest, but needs a working REST token + rate-limit headroom).
    #  2. The committed timings.json snapshot (rate-limit-proof; always in
    #     the checkout).
    #  3. Nothing -> bin_pack's median weighting balances by count.
    timing_dir = os.environ.get("QDB_TIMING_DIR", "surefire-timings")
    xmls = []
    if os.path.isdir(timing_dir):
        for dp, _d, fs in os.walk(timing_dir):
            xmls += [os.path.join(dp, f) for f in fs if f.endswith(".xml")]
    timings = load_timings(xmls)
    if not timings:
        timings = load_committed_timings()
        if timings:
            sys.stderr.write(f"generate.py: using committed timings.json ({len(timings)} classes)\n")
    classes = _discover_test_classes()
    return bin_pack(classes, timings, N_SHARDS)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    # --shards-only: emit just the weighted test-shard steps (no `steps:`
    # header), for splicing under the static pipeline's non-test legs. Default:
    # emit the standalone lint+shards proof-of-path pipeline.
    shards_only = "--shards-only" in argv
    try:
        changed = changed_paths()
        if changed and not select_shards(changed):
            # Docs/CI-only change: no test shards this run.
            sys.stdout.write(render_shard_steps([]) if shards_only else render_pipeline([]))
            return
        shards = _compute_shards()
        sys.stdout.write(render_shard_steps(shards) if shards_only else render_pipeline(shards))
    except Exception as e:  # never fail the build on a generator bug
        sys.stderr.write(f"generate.py failed ({e!r}); emitting static fallback\n")
        if shards_only:
            # In splice mode the caller already emitted the non-test legs, so a
            # generator failure must fall back to the three STATIC test legs,
            # not the whole static pipeline (which would duplicate every leg).
            _emit_static_test_legs()
        else:
            _emit_static_fallback()


def _emit_static_test_legs():
    """Print the three static test legs (griffin/cairo/other) as a fragment.

    The splice-mode fallback: if shard generation fails, the run still gets the
    original count-based test coverage without duplicating the non-test legs the
    caller already emitted.
    """
    try:
        with open(STATIC_TEST_LEGS) as f:
            sys.stdout.write(f.read())
    except OSError:
        sys.stdout.write(
            '  - label: ":coffee: test: all (fallback)"\n'
            "    agents: { queue: linux-large }\n"
            "    command: |\n"
            "      PRELUDE_NEED_CLIENT=1 source .buildkite/prelude.sh\n"
            "      mvn $MVN_COMMON clean test\n"
        )


if __name__ == "__main__":
    main()
