# Buildkite Linux + macOS smoke test — design

Date: 2026-07-29
Author: Steven Sklar
Status: approved for implementation

## Goal

Get one **green** Buildkite build running lint + tests + coverage against
QuestDB `core`, on Buildkite **hosted** agents, as an end-to-end smoke test in a
personal fork. This is a like-for-like proof that the Buildkite wiring works —
NOT a rebalance, NOT a dynamic pipeline, NOT a full port of Azure CI. Everything
deliberately cut is captured in "Going forward" below so nothing is lost.

Non-goal: replacing Azure CI now. This validates the platform and produces a
timing baseline for the real port.

## Context: what Azure CI does today (decomposition)

The OSS PR entrypoint is `ci/test-pipeline.yml` (self-hosted Hetzner). On a PR it
also fires `ci/test-hosted-pipeline.yml` (Microsoft-hosted mac/Windows) and
triggers the enterprise pipeline (id 23) via REST API. The main pipeline's
distinct tasks:

1. **CheckChanges** — curls the GitHub PR files API; computes
   `SOURCE_CODE_CHANGED`, `RUST_SOURCE_CODE_CHANGED`, the JaCoCo class list, and
   the coverage tool option. Gates every downstream stage via
   `stageDependencies...outputs[...]`.
2. **TriggerEnterpriseCI** — REST kick of enterprise pipeline 23 (skipped on forks).
3. **Griffin tests** — `**/griffin/**`, on 3 Linux variants (arm64, x64-zfs, x64-graal).
4. **Cairo A** — `**/cairo/*,**/cairo/fuzz/**` x 3 variants.
5. **Cairo B** — `o3/wal/mv/map/pool/view/vm/file/sql` x 3 variants.
6. **Other A** — `pgwire/http/std/log/sqllogictest/network` x 3 variants.
7. **Other B** — everything else x 3 variants.
8. **Coverage run** — 8-way matrix (griffin root/sub, fuzz1/2, cairo root/sub,
   pgwire, other) with JaCoCo + jemalloc `LD_PRELOAD` + Rust llvm-cov.
9. **JavaAndRustLint (aux)** — IntelliJ format check, unterminated-log check,
   Rust fmt/clippy/test (qdb-core, qdb-parquet-meta, qdbr, parquet2), compat
   tests, javadoc, bytecode-size check.
10. **CoverageReports** — merge JaCoCo + Rust LCOV, run cover-checker, post
    diff-coverage to the GitHub PR.

Shared step primitives (`ci/templates/steps.yml`): checkout, apt-mirror,
detect-local-client, select Maven settings (Reposilite vs Central), JDK/Graal
activation, build client native lib, Maven caches, compile, run tests,
crash-dump + log archival, coverage artifact upload.

Cross-cutting infra: Reposilite Maven cache (`maven.internal:8081`, a SPOF),
Hetzner apt mirrors, self-hosted pools (`hetzner-incus`, `-arm`, `-zfs`), the
enterprise REST trigger.

### Observed test shape (measured 2026-07-29)

1744 test classes under `core/src/test/java/io/questdb/test/`. Distribution:
`griffin` 1000 (57%; `griffin/engine` alone 759), `cutlass` 242
(qwp 75, line 58, http 53, pgwire 30, websocket 16), `cairo` 238, `std` 172.

The functional shard split is **count-imbalanced**: griffin (57% of classes) is
ONE leg while cairo's 238 classes get TWO legs. The coverage matrix already
splits griffin root/sub and pulls fuzz onto dedicated legs; the functional
shards do not. Class count != wall-clock (fuzz/O3 run many randomized iterations
and are slow per class), so a proper fix is runtime-weighted, not count-based.
Rebalancing is explicitly deferred (see Going forward); the smoke test ports the
existing split verbatim so it stays an honest like-for-like proof.

## Design

Replace `.buildkite/pipeline.yaml` (currently a hello-world) with a **static**
pipeline. Hosted agents only; clean-room. Because there is no Reposilite and no
Hetzner apt mirror, the entire `maven.internal:8081` detection dance, the
apt-mirror templates, and the self-hosted pool plumbing simply **drop away** —
Maven resolves from Central and JDK 25 is installed in-step. Removing that
fork-hostile complexity is itself one of the wins.

### Hosted queues (provisioned in the org)

| Queue | OS / arch | Size |
|-------|-----------|------|
| `linux-small` (default) | Linux AMD64 | 2 vCPU / 4 GB |
| `linux-medium` | Linux AMD64 | 4 vCPU / 16 GB |
| `linux-large` | Linux AMD64 | 8 vCPU / 32 GB |
| `macos-medium` | macOS ARM64 | 6 vCPU / 28 GB |
| `macos-large` | macOS ARM64 | 12 vCPU / 56 GB |

Steps target a machine with `agents: { queue: <name> }`.

### Steps (all run in parallel; no gating, no change detection)

| Step | Queue | Command essence | Mirrors Azure |
|------|-------|-----------------|---------------|
| **Lint** | `linux-small` | `find_unterminated_logs.py core/src`; Rust `cargo fmt --check` + `cargo clippy --all-targets -- -D warnings` on qdb-core, qdb-parquet-meta, qdbr; `ci/check-bytecode-size.sh` | aux-job / rust-test-and-lint (minus IntelliJ format) |
| **Test: griffin** | `linux-large` | `mvn clean test -Dtest.include=**/griffin/**` | SelfHosted Griffin (long pole) |
| **Test: cairo** | `linux-large` | `-Dtest.include=**/cairo/**` | Cairo A + B merged (both under-full) |
| **Test: other** | `linux-medium` | `-Dtest.exclude=**/griffin/**,**/cairo/**` | Other A + B merged |
| **Coverage** | `linux-medium` | `mvn test -P jacoco,qdbr-coverage -Dtest.include=**/std/**` + JaCoCo report merge | coverage matrix + CoverageReports (minimal proof-of-path) |
| **Test: macos griffin** | `macos-large` | same `**/griffin/**` shard as Linux | test-hosted-pipeline (mac), max signal overlap |

Two `linux-large` agents (griffin + cairo) run at once — acceptable and desired;
the fork is on a free trial with ample cores and will need this parallelism.

### Shared prelude per step

A small inline shell snippet (later factored to a script under `.buildkite/`):
1. Install / select JDK 25 (`JAVA_HOME`). Linux: openjdk-25. macOS: preinstalled
   or `brew`.
2. `git submodule update --init java-questdb-client`.
3. Build uses `-P local-client` because `core/pom.xml` carries a
   `-SNAPSHOT` `questdb.client.version` (mirrors `detect-local-client.yml`).
4. `-DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false` on test legs.

The `build-web-console` profile is dropped for the smoke test (needs Node and is
not required by the package-split test legs). Known caveat: `ServerMainTest`'s
`testServerUpgradeDoesNotOverrideWebConsoleConfig` wants the bundled console and
lands on the `other` leg. **Default decision:** exclude that one class on the
`other` leg (`-Dtest.exclude=...,**/ServerMainTest.java`) rather than pull Node
into the smoke test. If we later want it covered, add `-P build-web-console` to
just the `other` leg instead. Chosen so implementation is unblocked.

### Deliberate cuts (captured, not lost)

- Single x64 Linux + one macOS leg; no arm64 / zfs / graal Linux variants.
- No change detection / dynamic `pipeline upload`; every step always runs.
- No cover-checker diff-coverage posting to GitHub (needs PR context + token).
  Coverage step only proves the instrumented run + report merge is green.
- No IntelliJ format check (heavy 2GB download, formatter-pin churn), no
  enterprise trigger, no Windows, no compat/javadoc, no jemalloc `LD_PRELOAD`.
- Coverage on one small package (`**/std/**`), not the 8-way matrix.

## Going forward (the real port — documented, not built now)

- **Runtime-weighted auto-sharding.** Capture surefire/JUnit XML durations from
  these smoke runs as the baseline; a generator bin-packs classes into N
  roughly-equal-wall-clock shards. Fixes the griffin-is-57%-on-one-leg
  imbalance with real data.
- **Buildkite-native CheckChanges.** A bootstrap step runs a generator that
  diffs against master and `buildkite-agent pipeline upload`s only the needed
  shards; cross-step data via `buildkite-agent meta-data`.
- **Multi-platform matrix.** Re-add arm64 / zfs / graal Linux and Windows.
- **Re-add** cover-checker diff-coverage posting, the enterprise REST trigger,
  compat + javadoc, IntelliJ format check, jemalloc coverage.
- **Infra decision.** Self-hosted (Hetzner fleet, Reposilite/apt mirror) vs
  hosted for the production pipeline; Maven cache strategy without the SPOF.

## Testing / success criteria

- The Buildkite build goes green end-to-end on a push to the fork branch.
- Each test leg compiles `core`, runs its package subset, and reports results.
- The coverage leg produces a merged JaCoCo report artifact without error.
- The macOS leg runs the griffin shard to completion on ARM64.
- Surefire/JUnit XML is uploaded as a build artifact from each test leg (feeds
  the future runtime-weighted split).

Partial-green is expected on a first run in a fork (fork/infra gaps are fine per
the original ask); the objective is a working e2e loop and a clear list of what
still needs wiring.
