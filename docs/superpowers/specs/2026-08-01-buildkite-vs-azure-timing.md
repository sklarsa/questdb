# Buildkite vs Azure: head-to-head CI timing

Date: 2026-08-01
Author: Steven Sklar
Status: measurement complete

This is the fair timing comparison the Buildkite evaluation was building toward.
It is meaningful now, and not before, because the Buildkite custom agent image
is finally pinned to the linux queues (build #34 confirmed it active). Every
Buildkite number from builds below #34 carried a "plain-agent tax" -- a cold
toolchain download on every leg -- and is not comparable to Azure's warm
self-hosted pools. The numbers here come from a warm-image build (#44).

All numbers are freshly measured from live APIs on 2026-08-01 unless a line
explicitly marks a figure as remembered from baseline notes.

## 1. Methodology

### What was measured

Buildkite (org `questdb-1`, pipeline `questdb`), pulled from the REST API
(`/v2/organizations/questdb-1/pipelines/questdb/builds`):

- Build #44 -- the reference. A fully-green run of the whole static pipeline on
  the warm custom image, with the opt-in prelude and the native `.m2` cache
  active. Branch `buildkite-test`, commit `62d8cabb`. Started
  2026-08-01T03:18:39Z, finished 04:26:43Z.
- Build #42 -- a second green full-pipeline run, used only as a cross-check on
  how much the trial's agent cap moves the wall clock. It started at nearly the
  same minute as #44 (03:17Z) and competed with #44 for the same agent pool.

Per-leg durations come from each job's `started_at`/`finished_at`; the build
total comes from the build's own `started_at`/`finished_at`.

Azure DevOps (org `dev.azure.com/questdb/questdb`, pipeline id 1, "New pull
request"), pulled with a read-only PAT:

- Wall-clock distribution: the 100 most recent builds by finish time
  (`/build/builds?definitions=1`), spanning 2026-07-28 to 2026-08-01. To keep
  the percentiles honest, runs shorter than 15 min were dropped as fast-fail or
  aborted builds (they are not full runs); 80 full runs remained.
- Per-leg breakdown: the build timeline
  (`/build/builds/{id}/timeline`) for three succeeded builds near the median --
  257805 (41.9 min), 257712 (44.7 min), 257673 (41.2 min). Stage, job and task
  records give per-leg and per-task durations. The three agreed closely, so the
  leg table below cites 257805 and notes where the other two differ.

### Caveats (these bound how far the comparison can be pushed)

- Agent cap. The Buildkite trial runs at most 4 concurrent linux agents. On #44
  the pipeline has 9 linux legs plus a macOS leg, so most legs queue behind the
  4-agent limit rather than starting at t=0. This inflates the Buildkite wall
  clock well above the sum of what any single leg needs. Azure's self-hosted
  Hetzner fleet has enough pooled capacity that every stage starts within the
  first minute. A production Buildkite org would raise the cap; the 4-agent
  number does not bind there. This is the single largest distortion in the
  comparison and it works against Buildkite.
- Cross-build contention. #44 and #42 ran in the same minutes against the same
  4-agent pool, so each stole agents from the other. #44's queue waits are
  therefore an over-estimate of what a lone build would see, and #42's total
  (87.7 min) is inflated further. #44 is the cleaner of the two; #42 is reported
  only to show the spread.
- Warm vs cold image. Buildkite #44 runs the warm custom image. Azure runs warm
  self-hosted pools with a Reposilite Maven mirror and apt mirror. Both sides
  are warm here, which is the point of waiting for the image pin.
- Hosted vs self-hosted hardware. Buildkite legs run on hosted queues
  (`linux-large` 8 vCPU / 32 GB, `linux-medium` 4 vCPU / 16 GB, `linux-small`).
  Azure runs on the self-hosted Hetzner fleet (`hetzner-incus`, `-arm`, `-zfs`).
  The two do not have identical core counts, so per-leg times are not a pure
  software comparison; they compare the two systems as deployed.
- Coverage instrumentation differs. Azure runs an 8-way JaCoCo + jemalloc
  `LD_PRELOAD` + Rust llvm-cov coverage matrix over the whole test tree, and it
  is the Azure critical path. Buildkite #44 runs only a proof-of-path coverage
  leg over the `std` slice (3.5 min). These are not the same workload; the leg
  table flags this as the largest non-1:1 mapping.
- Change detection differs. Azure's CheckChanges skips legs whose sources did
  not change (e.g. compat and Rust tasks are near-zero in the sampled builds
  because those PRs did not touch them). Buildkite #44 runs every leg
  unconditionally. So Buildkite pays for legs Azure often skips, and Azure's
  measured p50 already reflects that skipping. Buildkite's dynamic generator
  (chunk 8) is built but not wired into #44.
- Scope is not identical. Azure runs each functional shard on 3 Linux variants
  (arm64, x64-zfs, x86-graal) and also fires macOS/Windows hosted legs and the
  enterprise pipeline. Buildkite #44 runs one x86 variant per shard plus one
  macOS griffin shard, and publishes nothing externally. Buildkite is doing less
  total work, which the verdict accounts for.

## 2. Leg-by-leg comparison

Buildkite figures are the leg runtime on #44 (not wall position). Azure figures
are the stage wall time (the slowest job in the stage) from build 257805, with
the 3-build range noted where it matters. "Runtime" excludes queue wait.

| Leg | Buildkite #44 runtime | Azure stage runtime | Mapping notes |
|-----|-----------------------|---------------------|---------------|
| lint (rust fmt/clippy + unterminated-log + bytecode) | 3.5 min | folded into the aux job (bytecode 0.3 min; Rust fmt/clippy near-zero when Rust unchanged) | Azure bundles lint into one aux job with format+javadoc; Buildkite splits it out. Not a clean 1:1. |
| format (IntelliJ) | 4.0 min | 4.0-4.8 min ("Applying formatting" task in aux job) | Close 1:1 on the task itself. Buildkite re-downloads the 2 GB IntelliJ every run (no persistent tool cache); Azure's "Install IntelliJ" is ~0.7 min warm. |
| javadoc | 2.3 min | 3.4-4.5 min ("Javadoc" task in aux job) | Clean 1:1. Buildkite is modestly faster here. |
| test: griffin | 7.6 min | 19.5-27.5 min (SelfHosted Griffin, 3 variants) | Not 1:1: Azure runs 3 OS variants and, in the median build, also instruments a griffin-root/-sub split inside the coverage matrix. Buildkite runs one x86 griffin shard. |
| test: cairo | 10.9 min | Cairo A 18.4 min + Cairo B 15.2 min (each x3 variants) | Not 1:1: Azure splits cairo into two stages across 3 variants; Buildkite merges into one leg on `linux-large`. |
| test: other | 16.6 min | Other A 16.3 min + Other B 24.6 min (each x3 variants) | Not 1:1: Azure splits other into two stages across 3 variants; Buildkite merges into one leg on `linux-medium`. This is Buildkite's slowest non-docker leg. |
| coverage | 3.5 min (std slice only) | 36.7 min (8-way JaCoCo matrix) + 4.5 min Coverage Report | No clean 1:1. Buildkite #44 runs proof-of-path only; Azure runs the full instrumented matrix and it is the Azure critical path. Comparing these two directly would be misleading. |
| compat | 1.8 min | folded into aux job; near-zero in sampled builds (change detection skipped it) | Buildkite runs it every time; Azure skips it when compat sources are unchanged. |
| docker build (no push) | 35.9 min | not in pipeline 1 (separate `docker-release-pipeline.yml`, release-triggered) | No 1:1 in the PR pipeline. On #44 docker is a full in-container build (mvn package + GraalVM + web console) from a cold layer cache; on #42 it was 2.6 min off a warm cache. This leg is the Buildkite critical path on #44. |
| macOS griffin | 8.3 min | runs in a separate `test-hosted-pipeline.yml` (Microsoft-hosted mac), not in the timeline sampled | Rough overlap only. On Buildkite the macOS leg runs on a separate `macos-large` pool, so it does not consume a linux agent. |
| enterprise trigger | not ported | 0.2 min (Trigger Enterprise CI) | Deliberately not ported. |

Where no clean mapping exists: coverage (proof-of-path vs full matrix), docker
(release pipeline vs PR pipeline), lint/format/javadoc/compat (Buildkite four
separate legs vs one Azure aux job), and the 3-variant fan-out (Azure runs
arm64/zfs/graal; Buildkite runs one x86 variant). The comparison is fair at the
level of "what gates a run" (section 4), less so leg-for-leg.

## 3. Total wall clock

| Metric | Buildkite | Azure |
|--------|-----------|-------|
| Reference build total | #44: 68.1 min (started->finished) | -- |
| Second green build | #42: 87.7 min (contended with #44) | -- |
| Full-run p50 | -- | 42.9 min (n=80 full runs, 4 days) |
| Full-run p90 | -- | 52.8 min |
| Full-run p95 | -- | 61.0 min |

Buildkite #44's 68.1 min is not a like-for-like wall clock against Azure's
42.9 min p50, and the reason is section 1's first caveat: the 4-agent cap. On
#44 the cairo leg did not even start until t=57.1 min (it waited 3471 s in
queue) and then ran only 10.9 min; the build finished at 68.1 min almost
entirely because of that queueing, not because cairo is slow. Peak observed
concurrency on linux was 3 agents, not even the full 4. Azure, with pooled
self-hosted capacity, starts every stage inside the first minute, so its total
is the critical path plus ~1 min of startup.

The apples-to-apples Buildkite number is the unconstrained critical path: with
unlimited agents every leg starts right after the 0.7 min pipeline upload, and
the wall clock becomes upload + the single longest leg. On #44 that is
0.7 + 35.9 (docker) = 36.6 min. If docker is excluded (it is a release-pipeline
concern, not a PR gate on Azure), the next longest leg is test:other at 16.6 min,
giving 0.7 + 16.6 = 17.3 min. So an uncapped Buildkite PR run of the ported legs
would land somewhere between ~17 and ~37 min depending on whether docker is on
the PR path, against Azure's 42.9 min p50. The 68.1 min headline is a trial-cap
artifact, not a property of Buildkite.

## 4. Critical-path analysis

### Buildkite #44: docker gates the run (at unlimited agents); the agent cap gates it in the trial

Two different things gate #44 depending on how you read it:

- Trial reality (4 agents): the wall clock is gated by queueing. Legs serialize
  2-deep behind the cap; cairo starts at t=57 min. The lever here is capacity --
  raise the agent cap. A production org with 9+ linux agents removes this gate
  entirely.
- Unconstrained (the fair read): the docker leg gates at 35.9 min. It is a full
  in-container build (mvn package + GraalVM + web console) and on #44 it hit a
  cold layer cache; #42 shows the same leg at 2.6 min warm. Levers to shorten
  it: keep the buildx layer cache warm across builds, or take docker off the PR
  critical path entirely (Azure already does -- docker lives in a separate
  release-triggered pipeline, not pipeline 1). With docker off the PR path, the
  Buildkite critical path drops to test:other at 16.6 min.

The test:other leg (16.6 min) is the slowest genuine test leg on #44 and would
become the critical path once docker is removed and the agent cap is lifted.
Lever: the weighted-sharding generator (chunk 8) splits by observed per-class
wall time; it is built and unit-tested but not wired into #44, and it directly
targets this leg.

### Azure: the coverage matrix gates every run

Across all three sampled builds the shape is identical: the "SelfHosted Running
tests with cover" stage runs 35.9-39.6 min and the "Coverage Report" merge runs
4.3-4.5 min immediately after it, so coverage + report is ~41-44 min and it is
the last thing to finish. Every functional test stage (griffin/cairo/other x3
variants) finishes by ~28 min, well inside the coverage stage. The p50 of
42.9 min is essentially "coverage stage + report + 1 min startup."

Within the coverage stage the longest shard is `on linux-other` at 36.5 min,
followed by `linux-griffin-sub` at 30.0 min; the other six shards finish between
11 and 23 min. So even the coverage stage is imbalanced -- one shard sets its
36.5 min length. Levers to shorten the Azure critical path: rebalance the
coverage matrix (its `other` and `griffin-sub` shards dominate), or reduce the
instrumentation cost (JaCoCo + jemalloc overhead is real). Neither is a quick
change; coverage instrumentation is intrinsically slower than a bare test run,
which is why it dominates.

## 5. Verdict

Buildkite is a credible replacement, and this timing round does not change that,
but the numbers cut in both directions and neither side is a clean win.

In Buildkite's favor: at unconstrained capacity the ported PR legs would finish
in roughly 17 min (docker off the PR path) to 37 min (docker on it), against
Azure's 42.9 min p50 and 52.8 min p90. The advantage is real but comes with an
asterisk -- Buildkite #44 is doing less work than the Azure run it is measured
against (one x86 variant per shard vs Azure's three variants, a proof-of-path
coverage leg vs Azure's full 8-way instrumented matrix, and nothing published
externally). A Buildkite pipeline that matched Azure's coverage scope would grow
a coverage leg of comparable weight and would likely inherit the same critical
path Azure has, so part of Buildkite's apparent lead is scope, not speed.

Against Buildkite: the trial's 4-agent cap makes the actual measured wall clock
(#44: 68.1 min, #42: 87.7 min) worse than Azure's p50, and the two green builds
disagree by ~20 min purely from cross-build contention. That cap is a trial
artifact and would not bind a production org, but it does mean this round cannot
show a green production-scale Buildkite wall clock -- only the per-leg runtimes
and the unconstrained critical-path estimate. The docker leg's 35.9 min cold
build is a genuine cost that only disappears with a warm layer cache or by
moving docker off the PR path. Azure's change detection also skips legs
(compat, Rust) that Buildkite #44 runs every time, so Azure's p50 already
benefits from work Buildkite has not yet wired to skip.

On balance: the per-leg runtimes favor Buildkite on the legs that map cleanly
(javadoc faster; test shards faster on the larger hosted agents), Azure is
faster end-to-end today because its capacity is not capped and its change
detection trims work, and the two critical paths are different problems --
Buildkite's is capacity plus an unpinned docker cache, Azure's is an imbalanced,
intrinsically-heavy coverage matrix. A fair production comparison needs three
things this trial lacks: enough Buildkite agents to remove the cap, a coverage
leg scoped to match Azure's matrix, and the weighted-sharding generator wired
in. Until then the honest summary is that Buildkite is competitive and probably
faster per leg, but its measured total here is cap-bound and not yet a proof of
a faster production run.
