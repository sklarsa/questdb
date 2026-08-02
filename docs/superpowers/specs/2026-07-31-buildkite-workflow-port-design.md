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
| 2 | self-hosted-cover-jobs.yml: LD_PRELOAD jemalloc under instrumentation | A coverage leg that installs libjemalloc and LD_PRELOADs it over the std slice | DEFERRED (open item) after 10 isolated builds. The install ALWAYS succeeded (`Setting up libjemalloc2`) and the diagnostics block ALWAYS found the file at /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 - yet EVERY resolver run in the step's command shell returned empty: an `ls /usr/lib/*/` glob (didn't expand), `ldconfig -p` (cache empty), `find /usr/lib` (agent /usr/lib is a symlink; find without -L doesn't descend), `find -L /` (crossed the symlink but HUNG 40+ min following symlinks), `find / -xdev` (empty - /usr is a separate MOUNT from /, -xdev stops at the boundary), plain `find /` (empty via head-1/SIGPIPE latching onto the client's bundled bin/.../libjemalloc.so), and finally a bare `test -e <exact path>` run flat in the parent shell (still empty, while dpkg -L in the same shell listed it). The consistent, unexplained signature: a lookup in the step shell fails while the identical lookup in the diagnostics block succeeds. Root cause is an unresolved hosted-agent filesystem-visibility quirk around sudo-apt-installed files. Highest-friction item of the port. Follow-up: retry on the CUSTOM agent image (bake libjemalloc into .buildkite/Dockerfile so no runtime install/lookup is needed at all). RESOLVED 2026-08-01 (see 2026-08-01-buildkite-deferred-chunks.md): the whole install-and-locate approach was a wrong turn - Azure never installs libjemalloc, it LD_PRELOADs the libjemalloc.so COMMITTED in the repo at core/src/main/bin/linux-x86-64/libjemalloc.so (git-tracked jemalloc 5.3.0 ELF), so there is nothing to discover. A second gotcha then surfaced (build #1 of questdb-jemalloc-deferred): this command wrapper pre-expands a bare $VAR at trace time, so a just-exported $LD_PRELOAD reads back EMPTY on its own line. Fix: recompute the path inline with $(pwd) and set LD_PRELOAD as an inline command-PREFIX on the process that needs it (no cross-reference), with a grep of /proc/self/maps that fails the step if jemalloc did not map. Build #2 PASSED: `jemalloc preloaded OK: 5 mappings`, 2748 std tests green under jemalloc. Dockerfile also bakes libjemalloc2 + /opt/libjemalloc.so as a belt-and-suspenders fallback. | 5 -> 1 (resolved) |
| 3 | java-lint.yml: pinned IntelliJ 2026.1.4, `idea.sh format`, fail on `git diff` | A leg that curls IntelliJ, runs the headless formatter, fails on any diff | 4 builds, all plain-agent env gaps (NOT the format logic): (1) `IDEA_ROOT="$PWD/..."` -> empty (env $PWD not populated); (2) `"$(pwd)/..."` ALSO empty because a non-exported var set on one line reads back empty on the NEXT line in the command wrapper - each line seems to run as a fresh shell, so only prelude's EXPORTED MVN_COMMON survives. Fix: relative `.ci/intellij`, no cross-line var. (3) `wget: command not found` on a plain agent -> use curl. Green once all three were addressed; the formatter ran over the real source tree and the tree was already clean. The 2GB download re-runs every build (no persistent tool cache) - the tool-cache friction this chunk was meant to probe. Minor: `.ci/` is left untracked (harmless; git diff --exit-code checks tracked files only). | 4 |
| 4 | test-fuzz.yml: `schedules: cron */15` on master, `%regex[.*Fuzz.*class]`, full reactor | Separate `questdb-fuzz` pipeline (inline config uploads pipeline.fuzz.yaml) + a REST-created hourly schedule; triggers off | Two real snags. (a) Buildkite schedules are NOT in-YAML like Azure `schedules:` - they are a pipeline-level object created via REST/UI, and need a whole second pipeline for isolation. (b) `-Dtest='*Fuzz*'` (the command-line SELECTOR) made the empty `benchmarks` module (surefire 2.17) abort the reactor with "No tests were executed!" even though all 72 fuzz classes passed - had to switch to the `-Dtest.include` PROPERTY like the other legs. Cadence reduced */15 -> hourly for the eval. | 3 |
| 5 | docker-release-pipeline.yml: buildx multi-arch build of core/Dockerfile (questdb + rhel targets), pushed | Same two `docker build --target` invocations, no push, no registry login; init the client submodule for the local-client build context | Green first try. Docker daemon + buildx are present on the hosted agent (backed by a `remote:nsc-remote` Namespace builder), so no QEMU/daemon setup needed. questdb target built 25/25 stages in ~181s (full in-container mvn package + GraalVM + web console); rhel target 26/26 in ~3s off cached layers. Does not source prelude.sh - the Dockerfile builds the whole toolchain in-container, sidestepping every plain-agent gap. Cleanest chunk after 1. | 1 |
| 6 | test-hosted-pipeline.yml (mac path): griffin shard on macOS | A macos-large step sourcing a brew-based macos-prelude.sh, running the griffin shard | Green first real run. macos-prelude.sh (apt->brew translation of prelude.sh) selected JDK 25.0.2 via Homebrew, built the client's libquestdb.dylib for darwin-aarch64 (CMake's ARCH_AARCH64 path, no nasm), and ran 989 griffin test classes to BUILD SUCCESS on the M4 (12 proc). The macos-large queue is a real hosted queue in the trial. No plain-agent gotchas here - macOS agents come with a working brew and the toolchain resolved cleanly. Only surface note: brew JDK path is /opt/homebrew/opt/openjdk/libexec/openjdk.jdk. | 2 |
| 7 | self-hosted-cover-jobs.yml: 8-way JaCoCo matrix + LCOV/cover-checker merge | Buildkite `matrix:` of 8 shards (verbatim Azure include/exclude), each `-P jacoco,qdbr-coverage`, + a merge step via ci/jacoco-merge.xml (-DincludeRoot) | PARTIAL - matrix STRUCTURE verified (griffin shards ran; YAML/patterns/merge wiring correct), but the 4 heavy shards (fuzz2, cairo-root, cairo-sub, pgwire) all failed at a tight 49.7-51.5 min cluster = the Buildkite hosted-agent ~50min DEFAULT JOB CAP (no pipeline timeout is set). Instrumented cairo/fuzz/pgwire runs on the slow PLAIN agent (toolchain re-downloaded each run, JaCoCo overhead, only 4 agents so shards serialize 2-deep) can't finish in the cap. Also proven: trial has only 4 hosted agents, so an 8-shard matrix is capacity-bound. Not a matrix-logic bug. Fixes: pin the custom image (saves the ~8-10min toolchain download/shard - blocked on agentImageRef, see chunk-2 follow-up), use linux-large, split heavy shards finer, or raise the job timeout. FOLLOW-UP RESULT: moving shards to linux-large FIXED the timeout - an isolated cairo-root ran in 8.7min (vs the 50min timeout on medium), a proven 5-6x speedup. The full matrix re-run on large no longer times out, but one shard (griffin-sub) still failed at 38min with exit 1 for an undiagnosed reason (Buildkite's log API returned a persistent 500 for that job, so the specific cause - genuine test failure vs OOM under instrumentation - is unretrievable; likely needs a fresh run once the custom image is pinned). Structure + large-agent sizing proven; a fully-green 8/8 matrix is the remaining open item. UPDATE 2026-08-01 (see 2026-08-01-buildkite-deferred-chunks.md): re-ran the full 8-way matrix on the WARM image, on linux-large, now also under the jemalloc LD_PRELOAD (throwaway pipeline questdb-cov-matrix-deferred build #1). griffin-sub did NOT reproduce its exit-1 this time - it ran clean past the old 38min death point; the prior failure correlates with the pre-image plain-agent toolchain-redownload pressure, gone now that tools are baked. No shard failed; heavy instrumented shards run ~30min each (jacoco+jemalloc, many randomized iterations) but stay under the ~50min cap. The 4-agent trial cap forces 3-wide serialization, so a full 8/8 pass takes > 1 hour end-to-end. | 4 -> 2 (infra-bound; griffin-sub exit-1 no longer reproduces on warm image) |
| 8 | check-changes-job.yml (change detection) + NEW runtime-weighted sharding | Python `generate.py` (bin-pack by surefire per-class time, median fallback, change detection) + `fetch_timings.py`, emitted via a bootstrap that `buildkite-agent pipeline upload`s; static-pipeline fallback on any error | Core built and unit-verified locally: 12 tests pass; dry-run over 1744 discovered classes with real build-#25 timings balanced 4 shards to 0.4% wall-time spread; with no timings it degrades to exact count-balance (436/436/436/436). Two integration notes, both follow-ups not blockers: (a) in-job timing fetch needs a REST token as a Buildkite SECRET - the agent access token cannot call the REST API, so without the secret the generator uses count-balanced sharding; (b) Buildkite trial artifact retention appears short - build #25's surefire XMLs were already ungettable when fetched later, so weighted sharding needs a fresh green build's artifacts. In-Buildkite bootstrap run still pending (agent + rate-limit contention). | 3 (core done, wiring pending) |

## Final evaluation: Buildkite vs Azure for QuestDB OSS CI

Written 2026-07-31 after the breadth-first port. Level-headed: the wins and the
costs both get equal weight.

### What ported cleanly (Buildkite is a good fit here)
- **Simple Maven legs** (compat, javadoc): trivial, green first try.
- **Docker build**: the single best result. Hosted agents ship a working docker +
  buildx backed by a `remote:nsc-remote` builder; a full in-container build
  (mvn package + GraalVM + web console) ran in ~3 min with no daemon/QEMU setup.
- **macOS**: `macos-large` (M4, arm64) worked first try - brew toolchain, native
  `.dylib`, 989 griffin classes green. Real, usable macOS capacity on the trial.
- **Scheduled jobs**: work, but the model differs (see costs).
- **Dynamic pipelines**: the `pipeline upload` mechanism is clean and made the
  weighted-sharding generator straightforward; the key measured win (griffin is
  57% of classes but ~1/3 of cairo's wall time) is directly addressable.

### What cost real effort (Buildkite friction, mostly hosted-agent env)
- **The custom agent image was never attached to the queues** (`agent_image_ref:
  null`), so every build ran on the PLAIN base agent. This one misconfiguration
  caused most of the pain below, and pinning it is **blocked**: `agentImageRef`
  is a Buildkite feature "under development" that needs enabling by their support
  (REST silently no-ops it; GraphQL rejects it). This is the top action item.
- **The plain agent is hostile**: no `wget`; `/usr` is a separate mount (breaks
  `find -xdev`); `/usr/lib` is a symlink (breaks symlink-naive `find`); and -
  the big one - **a non-exported shell var set on one line reads back empty on
  the next line** in the `command:` block (only `export`ed vars survive). That
  last quirk cost the most: it sank the format leg (`IDEA_ROOT` empty) and is the
  most likely real cause of the 10-build jemalloc saga (`JEM=$(...)` empty next
  line). Hardening rule: inline paths, keep set-and-use on one line, or export.
- **Job time cap**: hosted agents kill a job at ~50 min. The instrumented
  coverage shards blew past it on the slow/small `linux-medium` agent; moving to
  `linux-large` cut cairo-root from a 50-min timeout to **8.7 min**. Coverage
  must run on large agents.
- **Capacity**: the trial has **4 concurrent agents**, so an 8-shard matrix
  serializes 2-deep. Fine for an eval; a production port needs more agents.
- **Schedules and secrets are pipeline-level API objects**, not in-YAML like
  Azure `schedules:`. More moving parts; a scheduled job needs its own pipeline.
- **jemalloc**: deferred - a genuinely unexplained hosted-agent fs-visibility
  quirk (very possibly the same non-exported-var issue). Not worth more grinding
  until the custom image is pinned.

### Net read
Buildkite is a credible replacement and several things (docker, macOS, dynamic
pipelines) are nicer than the Azure/Hetzner status quo. But the plain-agent
environment is fragile enough that **the whole port hinges on pinning the custom
image** - once `agentImageRef` is enabled and attached, most of the friction
above (slow preludes, missing wget, likely jemalloc, the coverage timeouts)
should evaporate, because builds start warm with tools baked in. Recommend:
(1) email support@buildkite.com to enable `agentImageRef`; (2) size coverage on
`linux-large`; (3) add a REST token secret for weighted sharding; (4) revisit
jemalloc on the custom image. Only after (1) is a fair head-to-head timing
comparison against Azure meaningful - every number here carries the
plain-agent tax.

### Follow-up items (tracked)
- [ ] Enable + attach `agentImageRef` (custom image `linux-x86-test`) to the linux queues.
- [ ] Add a Buildkite secret with a read_builds+read_artifacts REST token for `fetch_timings.py`.
- [ ] Re-enable the jemalloc coverage leg on the custom image (or bake libjemalloc in).
- [ ] Run coverage shards on `linux-large`; consider splitting the heaviest.
- [ ] Re-add the deferred cover-checker diff-coverage GitHub posting, the enterprise REST trigger, Windows, and arm64/zfs/graal Linux variants.


## Post-eval optimization (custom image pinned + opt-in prelude)

After the breadth-first port, the custom agent image `linux-x86-test` was
attached to the linux queues via the Cluster UI (Queues -> queue -> Base image
-> Agent image dropdown). The REST/GraphQL API cannot set `agent_image_ref`
(feature-gated), but the console UI can - so this is a UI-only action. Build #34
confirmed it active (`Using JAVA_HOME=/opt/jdk`, no Temurin download).

With tools baked in, two per-leg costs were then made OPT-IN (default off), set on
the same line as `source` to avoid the empty-cross-line-var gotcha:
- `PRELUDE_NEED_RUST` - only the lint leg compiles Rust; ensure_rust dropped from
  10 legs to 1.
- `PRELUDE_NEED_CLIENT` - the -SNAPSHOT client build (submodule + CMake native +
  mvn install) runs only on legs that load client classes; format skips it.

Measured (plain-agent baseline #25 -> baked+opt-in #36, identical legs):
compat 3.2->2.3min (-28%), coverage 4.6->3.6min (-22%). Heavier legs benefit
more; the coverage matrix's ~50min timeouts are now well clear. Build #36 went
fully green (one test:other ServerMain-boot flake passed on retry - a known
non-deterministic setUp flake, unrelated to the prelude change).

Remaining redownload lever (not yet done): Maven `.m2` is re-resolved from
Central on every leg - Buildkite Cached Storage could persist ~/.m2.

### Maven .m2 caching (native hosted cache)

After the image pin + opt-in prelude, the last redownload was Maven: every leg
cold-resolved deps from Central (compat: 589 "Downloading from central" events
per run). First attempt used the community `cache-buildkite-plugin` - WRONG for
hosted agents: it caches to a local `/var/cache/buildkite` folder that does not
exist on ephemeral hosted agents, so its post-command save hook failed the build
even though the tests passed. The right mechanism is Buildkite's native
step-level `cache:` key (paths: ~/.m2/repository), which uses the hosted volume
cache (`hosted_container_cache_enabled=True`). Measured cold vs warm on compat:
589 -> 0 Central downloads (100%), 2.9 -> 2.4 min. The time win is modest because
deps download fast in parallel; the real value is RELIABILITY - zero per-build
dependency on Maven Central, which directly removes the flaky-Central-pull class
that plagued the Azure/Reposilite setup (Steven's #1 documented CI pain). Rolled
out to lint/griffin/cairo/other/compat/coverage/javadoc.

### Net optimization result
Baseline (plain agent, full prelude, no cache) -> optimized (pinned custom image
+ opt-in Rust/client + native m2 cache): ~22-28% faster per leg from the image +
prelude alone, plus elimination of all per-build Maven Central downloads. The
custom-image pin (a UI-only action - the API is feature-gated) was the master
unblock; everything else compounds on it.
