# Porting QuestDB CI workflows to Buildkite (breadth-first) — design

Date: 2026-07-31
Author: Steven Sklar
Status: approved for implementation

## Goal

Continue the Buildkite evaluation begun in
`2026-07-29-buildkite-linux-smoke-test-design.md`. That work landed a green
static smoke test (build #24: lint + griffin/cairo/other test shards +
proof-of-path coverage, hosted Linux x86). This effort ports the *remaining*
Azure CI workflows to Buildkite, **breadth-first** — one workflow at a time as
an independent, verified-green step — to surface Buildkite's rough edges across
many workflow *shapes* before investing in a dynamic-pipeline backbone.

The deliverable is two-fold:
1. A materially more complete Buildkite pipeline on the `buildkite-test` fork branch.
2. A scored **Buildkite Friction Log** (below) that turns "port stuff" into a
   real "should we switch off Azure?" evaluation.

Non-goal: replacing Azure CI now, or fork-safe external publishing (docker push,
GitHub PR coverage comments). Those are computed/built but not published.

## Key finding that reframes sharding (measured from build #24)

| Leg | Wall time | Class share |
|-----|-----------|-------------|
| test: griffin | 439s (7.3m) | 57% of classes |
| test: cairo | **1403s (23.4m)** — critical path | far fewer classes |
| test: other | 1096s (18.3m) | |
| lint | 237s | |
| coverage (std slice) | 237s | |

Count-based sharding is not merely imperfect, it is **inverted**: griffin is 57%
of classes but the *fastest* leg, while cairo (fewer classes, but slow
randomized fuzz/O3 iterations) is 3x longer and the actual critical path.
Weighted sharding must key on observed per-class wall time, not class count.

Crucially the data already exists: every test leg uploads
`core/target/surefire-reports/TEST-*.xml` as build artifacts (100 confirmed on
build #24), each carrying a per-class `time=` attribute. Weighted sharding is
therefore a bin-packing script over data we already collect, not a research
project — and it shares its entire mechanism (a bootstrap step that computes
something then `buildkite-agent pipeline upload`s a dynamic pipeline) with
change detection. One harness, two features.

## Decisions (locked)

- **Generator language: Python**, stdlib-only. Matches existing `ci/*.py`
  scripts; unit-testable; no build step on the bootstrap.
- **Timing source: last green build's artifacts.** Bootstrap pulls surefire XML
  from the most recent passing build on master via the Buildkite REST API.
  Self-updating, no committed timing data, always reflects reality.
- **New-class fallback: median observed per-class time.** Unknown classes are
  bin-packed at the median so a new class is placed reasonably; refresh corrects
  it next run.
- **Sequencing: breadth-first.** Each workflow ported as an independent static
  step first; the dynamic generator (change detection + weighted sharding) comes
  LAST, once real timing data has accrued from the earlier chunks.
- **macOS scope this round: one griffin shard** on `macos-large`, for maximum
  signal overlap with Linux at minimum agent surface.
- **External side effects: build/compute, do not publish.** Docker images build
  but do not push; coverage is computed and artifact'd but not posted to any PR.
- **Autonomous verification:** cleared to trigger builds on `questdb-1/questdb`
  for `buildkite-test` freely (trial credits are a non-concern). Report per
  chunk-complete or per real blocker, not per red build.

## Chunk plan (breadth-first; each lands green before the next)

| # | Chunk | Probes / why this order | Azure source |
|---|-------|-------------------------|--------------|
| 1 | Compat + javadoc | Additive Maven legs, low risk, full reactor + client native. Warm-up. | `compat-steps.yml`, `steps.yml` javadoc |
| 2 | jemalloc coverage leg | `LD_PRELOAD` on hosted agents — does the agent env cooperate. | `self-hosted-cover-jobs.yml` |
| 3 | IntelliJ format check | The ~2GB-download heavyweight — tool-cache pain on hosted agents. | `java-lint.yml` |
| 4 | Fuzz (scheduled) | Buildkite scheduled builds (cron) + long randomized jobs. | `test-fuzz.yml` |
| 5 | Docker build (no push) | docker-in-Buildkite, multi-arch buildx, no registry creds. | `docker-release-pipeline.yml` |
| 6 | macOS griffin shard | macOS agent + toolchain (brew JDK, native build). | `test-hosted-pipeline.yml`, `hosted-jobs.yml` |
| 7 | Coverage matrix (8-way) | Expand proof-of-path to the real matrix + JaCoCo/LCOV merge. | `self-hosted-cover-jobs.yml`, CoverageReports |
| 8 | Dynamic generator | Backbone rewrite: change detection + weighted sharding, with real data. | `check-changes-job.yml` + new |

## Repo structure (on `buildkite-test`)

```
.buildkite/
  pipeline.yaml          # static backbone (exists); chunks 1-7 add steps here
  pipeline.fuzz.yaml     # separate scheduled pipeline (chunk 4)
  prelude.sh             # shared setup (exists); extended per chunk
  Dockerfile             # custom agent image (exists)
  macos-prelude.sh       # NEW (chunk 6): macOS toolchain setup
  generate.py            # NEW (chunk 8): dynamic pipeline generator + unittests
```

Commits are throwaway on this fork eval branch — no history fuss.

## Verification loop (autonomous, per chunk)

1. Commit + push to `buildkite-test`.
2. Trigger a build via REST `POST /builds` (scoped to the affected step where
   possible, via a build `env` var read by a step-level `if`, so iterating a
   javadoc leg does not pay 23m of cairo).
3. Poll build + pull failing logs (`read_builds`, `read_build_logs`), fix, repeat.
4. Report only on chunk-complete or a real blocker (missing secret, unprovisioned
   macOS agent, plan limit). Verify by reading logs — the leg must do real work,
   not silently no-op.

## Testing & success criteria

- `generate.py` (chunk 8) has stdlib `unittest` coverage: bin-pack balance
  (max shard within a bounded % of mean), median fallback for unknown classes,
  malformed/empty XML handling. A generator exception must fall back to the
  static split, never fail the build.
- Chunks 1-7 each land green on `buildkite-test`, with the leg demonstrably doing
  real work (jemalloc: `LD_PRELOAD` took effect; docker: image built; etc.).
- Chunk 8 produces balanced shards (cairo no longer ~3x griffin) and emits only
  affected shards on a scoped diff.
- Nothing publishes externally.
- The Friction Log has a scored row per chunk.

## Buildkite Friction Log (the evaluation artifact)

Filled in as each chunk lands. Score 1 (frictionless) - 5 (painful). Columns:
what Azure did, the Buildkite mapping, what fought back + the fix, score.

| Chunk | Azure mechanism | Buildkite mapping | Friction (what fought back) | Score |
|-------|-----------------|-------------------|-----------------------------|-------|
| (smoke) | Reposilite cache, apt mirror, self-hosted pools | Central + in-step JDK; hosted queues | bytecode-check glob eaten by command wrapper; UTF-8 locale unset on plain agents; JaCoCo file-count > 5000 artifact cap | 2 |
| 1 | aux-job javadoc goal + compat-steps compat/cliutil test run (Maven tasks) | Two additive inline steps on linux-medium; compat uploads surefire XML | None. Both went green first try (build #25). Verified real work: compat ran 66 compat + 24 cliutil tests (0 fail); core javadoc actually generated (`No previous run data found, generating javadoc` + real per-file warnings). `-P javadoc`/`-P qdbr-release` live in core/pom.xml but activate fine from a root `mvn`; other modules correctly skip. | 1 |
| 2 | | | | |
| 3 | | | | |
| 4 | test-fuzz.yml: `schedules: cron */15` on master, `%regex[.*Fuzz.*class]`, full reactor | Separate `questdb-fuzz` pipeline (inline config uploads pipeline.fuzz.yaml) + a REST-created hourly schedule; triggers off | Two real snags. (a) Buildkite schedules are NOT in-YAML like Azure `schedules:` - they are a pipeline-level object created via REST/UI, and need a whole second pipeline for isolation. (b) `-Dtest='*Fuzz*'` (the command-line SELECTOR) made the empty `benchmarks` module (surefire 2.17) abort the reactor with "No tests were executed!" even though all 72 fuzz classes passed - had to switch to the `-Dtest.include` PROPERTY like the other legs. Cadence reduced */15 -> hourly for the eval. | 3 |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
