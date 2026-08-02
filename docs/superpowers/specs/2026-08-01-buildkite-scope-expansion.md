# Buildkite scope expansion: reaching Azure parity and beyond -- planning

Date: 2026-08-01
Author: Steven Sklar
Status: planning (evaluation is green; this scopes the real migration)

## Purpose

The breadth-first Buildkite evaluation (see
`2026-07-29-buildkite-linux-smoke-test-design.md` and
`2026-07-31-buildkite-workflow-port-design.md`) proved that Buildkite can run
QuestDB's core CI shapes on hosted agents. That work deliberately stopped at a
subset of the Azure DevOps pipelines and published nothing externally. This
document is the planning artifact for the next step: what it takes to reach full
parity with the Azure pipelines, where Buildkite can improve on the current
process, the risks that remain, and a recommended order of work.

The parity checklist below is derived from the actual Azure YAML in this repo
(`ci/*.yml`, `ci/templates/*.yml`) and the GitHub Actions workflows
(`.github/workflows/*.yml`), not from memory. Every row names the source file.

## Scope note: what lives where

QuestDB OSS CI is split across three systems today:

- Azure DevOps (`ci/`): the PR test pipeline, the on-demand hosted mac/Windows
  pipeline, the scheduled fuzz pipeline, and the release pipelines (docker,
  GitHub binaries, AMI). This is the bulk of what a Buildkite migration replaces.
- GitHub Actions (`.github/workflows/`): a set of smaller checks (Danger,
  Gitleaks, glibc smoke test, parquet compat, pgwire/R third-party-client
  compat, Rust license check) plus manually-dispatched native-library rebuild
  jobs. These are functional and cheap; they are not an Azure cost and are out of
  the migration's critical path, but they are listed for completeness.
- The language client CI (Python / C / .NET on Azure DevOps; Java / Go / Node.js
  on GitHub Actions) lives in the separate client repositories, not in this
  monorepo. Their pipeline YAML is not present here, so this document treats them
  as an external, out-of-scope dependency and flags them as "not-started, not in
  this repo" rather than inventing a plan for files it cannot read.

---

## 1. Parity gap analysis

Status legend:
- ported -- runs green on the Buildkite eval branch (`buildkite-test`).
- partial -- structurally proven but with an open item (timeout, missing secret,
  one failing shard).
- deferred -- consciously excluded from the eval, mechanism understood.
- not-started -- no Buildkite work yet.

### 1a. Main PR pipeline (`ci/test-pipeline.yml`, 8 stages)

| Azure stage / job (source) | Buildkite status | What it takes on Buildkite |
|---|---|---|
| `CheckChanges` -- curls GitHub PR files API, computes `SOURCE_CODE_CHANGED`, `RUST_SOURCE_CODE_CHANGED`, the JaCoCo class list, coverage tool (`ci/templates/check-changes-job.yml`) | partial | `generate.py` + a bootstrap step do change detection via `git diff --name-only origin/master...HEAD` and skip test shards on docs/CI-only diffs. Core is unit-tested (12 tests). Class-level coverage-diff computation (the `COVERAGE_DIFF` `+:*.Class` list) is NOT reproduced -- it is only consumed by cover-checker, which the eval does not post. Wiring the git-diff path into a live PR build remains. |
| `TriggerEnterpriseCI` -- REST kick of enterprise ADO pipeline 23, fork-gated, GitHub-status reported back (`ci/test-pipeline.yml` lines 44-124) | not-started | Two options. (a) If enterprise CI also moves to Buildkite, a native `trigger` step handles this cleanly (pass `commit`/`branch`/`env`, `async: true` to fire-and-forget, `soft_fail` so an enterprise flake does not fail OSS). (b) If enterprise stays on ADO, keep a `command:` step doing the same `curl` POST to the ADO REST API; the GitHub PR head-SHA lookup and branch-match logic port verbatim. The status-report-back is a GitHub commit status, which Buildkite can post. This is a genuine integration, not a lift-and-shift. See docs: [trigger-step](https://buildkite.com/docs/pipelines/configure/step-types/trigger-step). |
| `SelfHostedRunGriffin` -- `**/griffin/**` x {arm64, x64-zfs, x64-graal} (`ci/templates/self-hosted-jobs.yml`) | partial (x86 only) | The x86 griffin leg is green. The three Azure VARIANTS (arm64, zfs, graal) are not ported. arm64 Linux hosted agents exist but are Enterprise-plan-gated (see Risks). zfs has no hosted equivalent (it tests a specific filesystem; would need a self-hosted agent). graal needs GraalVM baked into a custom image. |
| `SelfHostedRunCairoA` -- `**/cairo/*,**/cairo/fuzz/**` x 3 variants (`self-hosted-jobs.yml`) | partial (x86, merged) | The eval merges Cairo A+B into one x86 `test: cairo` leg. Same 3-variant gap as griffin. |
| `SelfHostedRunCairoB` -- `**/cairo/{o3,wal,mv,map,pool,view,vm,file,sql}/**` x 3 variants | partial (x86, merged) | Merged into `test: cairo`. 3-variant gap. |
| `SelfHostedRunOtherA` -- `pgwire,http,std,log,sqllogictest,network` x 3 variants | partial (x86, merged) | Merged into `test: other`. 3-variant gap. |
| `SelfHostedRunOtherB` -- everything else x 3 variants | partial (x86, merged) | Merged into `test: other`. 3-variant gap. |
| `SelfHostedRunTestsCoverageBranches` -- 8-way JaCoCo matrix + jemalloc `LD_PRELOAD` + Rust llvm-cov (`ci/templates/self-hosted-cover-jobs.yml`) | partial | Matrix STRUCTURE proven on `linux-large` (griffin shards green; cairo-root 8.7 min vs a 50 min timeout on medium). Open items: one shard (griffin-sub) failed undiagnosed; jemalloc `LD_PRELOAD` deferred (a hosted-agent filesystem-visibility quirk -- bake libjemalloc into the custom image to sidestep it); the Rust llvm-cov half of the matrix is not wired on Buildkite. A fully-green 8/8 is the remaining work. |
| `JavaAndRustLint` (aux-job) -- see 1b below | mixed | Broken out below because it bundles six distinct checks. |
| `CoverageReports` -- merge JaCoCo + Rust LCOV, run cover-checker, POST diff-coverage to the GitHub PR at a 50% threshold (`ci/test-pipeline.yml` lines 190-334, `ci/jacoco-merge.xml`, `ci/merge_lcov_paths.py`, `ci/lcov_cobertura.py`, `ci/cover-checker-1.5.0-all.jar`) | partial | JaCoCo merge is proven (`ci/jacoco-merge.xml verify -DincludeRoot=core/target`). NOT ported: the Rust LCOV -> Cobertura conversion, and the cover-checker GitHub PR post (needs the PR diff, a `GH_TOKEN` secret, and the PR number). The post is a real side effect the eval refused to publish. Buildkite can run the same `cover-checker` jar in a `command:` step; the gap is secrets + PR context, not compute. |

### 1b. Aux lint job (`ci/templates/aux-job.yml`, `java-lint.yml`, `rust-test-and-lint.yml`)

| Azure check (source) | Buildkite status | What it takes on Buildkite |
|---|---|---|
| unterminated-log check -- `find_unterminated_logs.py core/src` (`aux-job.yml` via `java-lint.yml:2`) | ported | Runs in the `lint` leg. |
| IntelliJ format check -- pinned `idea-2026.1.4`, `idea.sh format`, fail on `git diff` (`java-lint.yml:4-42`) | ported | The `format` leg is green. The 2 GB IntelliJ download re-runs every build (no persistent tool cache); Azure's self-hosted agents keep it at `/opt/intellij`. Baking IntelliJ into the custom image removes the download, matching Azure's warm path. |
| Rust fmt + clippy on qdb-core, qdb-parquet-meta, qdbr (`rust-test-and-lint.yml:16-45`) | ported | Runs in the `lint` leg (three flat per-crate invocations). |
| Rust `cargo test` on qdb-core, qdb-parquet-meta, qdbr, parquet2 with coverage instrumentation + LCOV upload (`rust-test-and-lint.yml:50-141`) | not-started | The eval runs fmt+clippy but NOT the four instrumented `cargo test` runs, the parquet2 submodule init, `install-llvm.yml`, or the profraw->LCOV pipeline. This is real missing coverage of the Rust test suites. |
| compat + cliutil tests -- `**/compat/**,**/cliutil/**` full reactor (`compat-steps.yml`) | ported | The `compat` leg is green (66 compat + 24 cliutil tests). |
| javadoc -- `mvn compile javadoc:javadoc -P javadoc -P qdbr-release` (`aux-job.yml:47-56`) | ported | The `javadoc` leg is green. |
| bytecode-size check -- `ci/check-bytecode-size.sh --threshold 8000` (`aux-job.yml:59-67`) | ported | Runs in the `lint` leg. |

### 1c. Hosted mac/Windows pipeline (`ci/test-hosted-pipeline.yml` -> `ci/templates/hosted-jobs.yml`)

| Azure job group (source) | Buildkite status | What it takes on Buildkite |
|---|---|---|
| macOS matrix: griffin-base, griffin-sub, griffin-fuzz, cairo, cairo-fuzz, pgwire, other (7 groups, `hosted-jobs.yml:6-99`) | partial | The eval runs ONE macOS griffin shard on `macos-large` (M4, arm64), green. The other six mac groups are not ported. macOS hosted agents are real and usable on the trial, so this is a matter of adding groups and paying for macOS minutes (Mac M4 bills at a higher per-minute rate than Linux -- see cost model). |
| Windows matrix: griffin-base/sub, fuzz1/2, cairo-1/2, pgwire, other-1/2 (10 groups, `hosted-jobs.yml:100-222`) | not-started | Buildkite has NO Windows hosted agent (Linux and macOS only). Azure's enterprise critical path includes a hosted Windows leg (~53 min). To match this on Buildkite requires either a self-hosted Windows agent (the Buildkite agent runs on Windows) or keeping Windows on Azure/GitHub Actions. This is the single largest platform gap. |

### 1d. Scheduled and release pipelines

| Azure pipeline (source) | Buildkite status | What it takes on Buildkite |
|---|---|---|
| Scheduled fuzz -- cron `*/15` on master, `%regex[.*Fuzz.*class]`, 60 min (`ci/test-fuzz.yml`) | ported (cadence reduced) | `pipeline.fuzz.yaml` runs green; a schedule was created via REST. Buildkite schedules are a pipeline-level object (Settings > Schedules), not in-YAML like Azure `schedules:`, and only guarantee a 10-minute granularity, so the `*/15` cadence is feasible but the eval reduced it to hourly to conserve trial agents. |
| Docker release -- buildx multi-arch (amd64+arm64) build of `core/Dockerfile` questdb + rhel targets, push-by-digest to Docker Hub, nightly/tag/branch variants, `serviceaccountquestdb` registry login (`ci/docker-release-pipeline.yml`) | partial (build only) | The BUILD is the cleanest chunk in the eval: hosted agents ship docker + buildx (backed by a `remote:nsc-remote` builder), questdb + rhel targets built with no push. NOT ported: the Docker Hub login (needs a registry-credentials secret), the actual `push=true` + digest capture, the multi-arch manifest assembly, and the nightly/tag/branch trigger logic (tag-triggered builds). Multi-arch push needs the arm64 build path too. |
| GitHub binary release -- GraalVM CE 25 native binaries on Linux + Windows, tag-triggered (`ci/github-release-pipeline.yml`) | not-started | Linux half is feasible (GraalVM in a custom image or downloaded in-step, as Azure does). Windows half hits the same no-Windows-hosted-agent wall as 1c. Tag-triggered builds map to a Buildkite pipeline filtered on tags. |
| AMI marketplace publish -- AWS AMI build/publish, `AWS_*` creds (`ci/ami-market-pipeline.yml`) | not-started | A single `command:` step running `make build_release` with AWS creds from a secret. Low complexity once secrets are wired; low frequency. |
| PR-title validation (`ci/validate-pr-title/`, Danger) | not-started (runs on GHA) | Already runs as a GitHub Action (`danger.yml`); no need to move it. Listed for completeness. |

### 1e. GitHub Actions checks (`.github/workflows/`) -- not an Azure cost, listed for completeness

| Workflow | Trigger | Migration stance |
|---|---|---|
| `danger.yml`, `gitleaks.yml`, `rust_license_check.yml` | PR / push | Leave on GHA (cheap, GitHub-native). |
| `glibc_smoke_test.yml`, `parquet_compat.yml` | PR / dispatch | Leave on GHA, or fold into Buildkite later if consolidation is wanted. |
| `pgwire_latest.yml` (schedule), `pgwire_stable.yml`, `r_test.yml` | schedule / PR | Third-party-client compat matrices. Leave on GHA. |
| `rebuild_*.yml` (native libs, rust, async-profiler, win64svc) | `workflow_dispatch` | Manual artifact-rebuild jobs; leave on GHA (they build committed binaries and include a Windows target). |
| `release_website.yml` | release | Leave on GHA. |

### Parity tally

Counting the concrete rows in 1a-1d (the Azure work a migration must replace;
excluding 1e GHA checks that stay put and the out-of-repo client pipelines):

- ported: 8 (unterminated-log, IntelliJ format, rust fmt/clippy, compat,
  javadoc, bytecode check, scheduled fuzz, and the x86 functional test legs as a
  merged group).
- partial: 8 (CheckChanges, the four functional shard stages as x86-only merges,
  the coverage matrix, CoverageReports JaCoCo-merge half, macOS matrix, docker
  build-only).
- deferred: 1 (jemalloc `LD_PRELOAD` coverage leg).
- not-started: 8 (enterprise REST trigger + status, Rust `cargo test` coverage
  suites, cover-checker GitHub post, Windows matrix, docker push + registry
  login, GitHub binary release, AMI publish, arm64/zfs/graal Linux variants).

The out-of-repo client pipelines (Python/C/.NET on ADO; Java/Go/Node on GHA) are
a separate not-started category that this repo cannot plan in detail.

---

## 2. Improvement opportunities

Each item states the win and the cost honestly.

### 2.1 Runtime-weighted sharding, and possibly Test Engine, in place of count-based splits

The eval's headline measurement is that count-based sharding is inverted:
griffin is 57% of test classes but roughly one third of cairo's wall time, so
cairo is the critical path despite having fewer classes (see the 2026-07-31
design doc). `generate.py` already bin-packs by observed per-class surefire time
and balanced four shards to a 0.4% wall-time spread on real data. This is a
concrete improvement over the hand-tuned Azure include/exclude lists in
`hosted-jobs.yml` and `self-hosted-cover-jobs.yml`, which are maintained by hand
and drift.

Buildkite also offers Test Engine (test splitting), which partitions tests using
historical timing collected by its own collectors and re-balances continuously
([test-splitting](https://buildkite.com/docs/test-engine/test-splitting),
[configuring](https://buildkite.com/docs/test-engine/test-splitting/configuring)).
Tradeoffs, stated plainly:
- Test Engine's automatic splitters support Cypress, Jest, Playwright, Pytest,
  and RSpec -- NOT JUnit/surefire, which is what QuestDB uses. Using it for Java
  would require the manual/generic split path, at which point it overlaps heavily
  with the `generate.py` we already have.
- Test splitting is a Pro/Enterprise-plan feature, so it is not free.
- The in-house `generate.py` is stdlib-only, unit-tested, and already tuned to
  QuestDB's surefire XML, so the marginal benefit of adopting Test Engine for
  Java is small. The honest recommendation is to keep `generate.py` for the Java
  shards and revisit Test Engine only if the org adopts it elsewhere.

### 2.2 Dynamic change-detection to skip unaffected legs

Azure's `check-changes-job.yml` computes booleans and every downstream stage
gates on them, but the stages still spin up agents to evaluate the condition.
Buildkite's dynamic `pipeline upload` lets `generate.py` emit ONLY the needed
steps, so a docs-only PR produces a lint-only pipeline with no test agents
created at all. Combined with step-level `if:` conditionals and `depends_on` /
`allow_dependency_failure`
([depends-on](https://buildkite.com/docs/pipelines/configure/depends-on),
[trigger-step](https://buildkite.com/docs/pipelines/configure/step-types/trigger-step)),
this is a cleaner and cheaper model than Azure's always-instantiated stages. The
cost is that the generator is now load-bearing; its static-fallback path (print
the committed static pipeline, exit 0 on any error) must stay well-tested so a
generator bug can never wedge CI.

### 2.3 Hosted docker and macOS that were painful before

The eval's two smoothest chunks were docker (full in-container build in ~3 min,
no QEMU/daemon setup, buildx backed by a remote builder) and macOS (`macos-large`
M4 arm64, brew toolchain, native `.dylib`, green first run). On Azure, the
Microsoft-hosted mac/Windows agents are the on-demand pipeline precisely because
they are the awkward path. Buildkite's hosted docker and macOS remove setup that
Azure makes the team carry. The tradeoff is cost: Mac M4 minutes bill at roughly
0.18-0.36 USD/min versus Linux at 0.013-0.052 USD/min
([pricing](https://buildkite.com/pricing/)), so a full 7-group macOS matrix is
materially more expensive per run than the single eval shard.

### 2.4 Native Maven cache removes the Reposilite single point of failure

Azure's self-hosted path depends on a Reposilite cache at `maven.internal:8081`
reached over the Hetzner vSwitch. `ci/test-pipeline.yml` carries a long comment
block and a set of wagon retry flags (`MAVEN_RUN_OPTS`) that exist ONLY to
survive dropped TCP SYNs to that single-IP, failover-less cache -- the team's #1
documented CI pain. Buildkite's native step-level `cache:` (paths:
`~/.m2/repository`) on the hosted volume cache took compat from 589 cold Central
downloads to 0 warm, and more importantly removes the per-build dependency on any
shared cache host. This is a reliability improvement, not just a speed one. The
tradeoff: the hosted cache is Buildkite-managed and opaque; there is no
Reposilite dashboard, and cold-cache builds still pull from Central directly (no
mirror), so a Maven Central outage is now unmitigated rather than absorbed by
Reposilite.

### 2.5 Better artifact and annotation UX for failures

Azure archives crash dumps and logs on failure via `PublishBuildArtifacts`
(`steps.yml:270-329`). Buildkite's annotations can surface a failing-test summary
inline on the build and as a GitHub check with per-line annotations
([notify](https://buildkite.com/docs/pipelines/configure/notify)), which is
richer than Azure's artifact-only story. The `retry` (automatic on specific exit
codes) and `soft_fail` attributes
([command-step](https://buildkite.com/docs/pipelines/configure/step-types/command-step))
also give a cleaner way to handle QuestDB's known non-deterministic setUp flakes
than Azure's stage-rerun. Tradeoff: annotations are a new surface to maintain,
and over-using `soft_fail`/`retry` can mask real regressions, so they need a
policy (retry only known-flaky exit signatures, never a blanket retry).

### 2.6 Burst capacity versus an idle Hetzner fleet

The Hetzner self-hosted fleet is provisioned for peak and idle most of the day.
Buildkite hosted agents bill per minute
([pricing](https://buildkite.com/pricing/)), so burst capacity is paid for only
when builds run. For a ~20-PR/day shop with a ~40-min run and a 40-min-idle
average, per-minute billing can be cheaper than a standing fleet -- but this is
NOT guaranteed: a sustained high-concurrency day (many PRs plus the scheduled
fuzz plus coverage matrices) can exceed the fixed fleet cost, and concurrency on
hosted agents is capped by plan vCPU
([hosted-agents/linux](https://buildkite.com/docs/pipelines/hosted-agents/linux)).
The honest position: model the real monthly minute volume before assuming a
saving. The reliability and maintenance win (no fleet to patch, no Reposilite to
babysit) is more certain than the raw cost win.

---

## 3. Risks and unknowns

### 3.1 Trial-only limits observed (a paid org changes these)

- 4 concurrent hosted agents. An 8-shard coverage matrix serialized 2-deep. A
  production org sizes concurrency by plan vCPU
  ([hosted-agents/linux](https://buildkite.com/docs/pipelines/hosted-agents/linux)),
  so this is a plan-tier choice, not a hard ceiling -- but it is a direct cost
  lever, and the full parity matrix (functional legs x 3 variants + 8 coverage
  shards + mac 7 + fuzz) needs far more than 4.
- The ~50 min job cap that timed out the instrumented coverage shards on
  `linux-medium` is the DEFAULT; hosted Linux instances support up to 8 hours,
  and moving those shards to `linux-large` cut cairo-root to 8.7 min. So the cap
  is really an agent-sizing issue, resolved by sizing up (at higher per-minute
  cost) or splitting shards finer.
- Short artifact retention on the trial made build #25's surefire XML
  ungettable when the weighted-sharding fetch ran later. A paid org sets its own
  retention; the generator must still tolerate missing timings (it degrades to
  count-balanced sharding).
- `agentImageRef` (attaching the custom `linux-x86-test` image to the queues)
  was gated during the eval and set only via the Cluster UI (the REST/GraphQL
  API silently no-ops it). It was ultimately attached via the UI and measured a
  22-28% per-leg speedup. The risk: this is a UI-only, feature-gated action, so
  reproducing the environment in a fresh org depends on that feature being
  enabled. The whole plain-agent friction class (missing wget, `/usr` mount
  quirks, the empty-cross-line-var gotcha, likely jemalloc) hinges on the custom
  image being pinned.

### 3.2 Platform gaps with no hosted answer

- No Windows hosted agent exists (Linux + macOS only). Azure's enterprise
  critical path includes a ~53 min hosted Windows leg, and
  `github-release-pipeline.yml` builds a Windows binary. Matching this needs a
  self-hosted Windows agent or keeping Windows on Azure/GHA. This is the biggest
  unknown for a full cutover.
- arm64 Linux hosted agents exist but are Enterprise-plan-gated
  ([hosted-agents/linux](https://buildkite.com/docs/pipelines/hosted-agents/linux)),
  so the arm64 functional variant costs a plan upgrade.
- The zfs variant tests a specific filesystem and has no hosted equivalent; it
  would require a self-hosted zfs agent, reintroducing the fleet the migration
  aims to retire.

### 3.3 Secrets and external side effects

Every external side effect the eval refused to publish needs a secret and a
policy: the enterprise ADO REST trigger (`AZURE_DEVOPS_ENT_PAT`, `GH_TOKEN`),
the cover-checker GitHub PR post (`GH_TOKEN` + PR number), Docker Hub push
(registry creds), AMI publish (`AWS_*`), and the weighted-sharding REST token.
Buildkite offers a native encrypted secret store scoped to a cluster, with
log-redaction, accessed via `buildkite-agent secret get` or the Secrets plugin
([buildkite-secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets),
[secrets overview](https://buildkite.com/docs/pipelines/security/secrets)), and
also supports external stores (AWS SM, Vault) via plugins
([managing secrets](https://buildkite.com/docs/pipelines/security/secrets/managing)).
The risk is not capability but blast radius: on a public fork, a leaked token in
a PR-triggered build is a real exposure, so secret-bearing steps must be gated to
non-fork, trusted builds (as Azure already does with the `IsFork` conditions).

### 3.4 Generator as a load-bearing component

Moving change-detection and sharding into `generate.py` concentrates risk in one
script. Its static-fallback path is tested, but the live integration (fetching
last-green timings via a REST token secret, running inside the bootstrap under
agent rate limits) was still pending at the end of the eval. Until that runs
green on a real PR, the dynamic backbone is unproven end-to-end.

---

## 4. Recommended sequencing

A phased plan, ordered so each phase unblocks the next and so the highest-value,
lowest-risk parity lands before the platform-gap hard problems.

### Phase 0 -- Establish a paid production org and pin the image

- Move off the trial to a plan with enough concurrency for the real matrix and
  longer artifact retention.
- Confirm `agentImageRef` is enabled and attach the custom `linux-x86-test`
  image (JDK 25 + Maven + Rust, plus IntelliJ, libjemalloc, and GraalVM baked
  in) to the Linux queues. This is the master unblock for the plain-agent
  friction class and should precede any timing comparison against Azure.
- Add the Buildkite cluster secrets needed downstream (REST token for
  `fetch_timings.py`, `GH_TOKEN`, and the enterprise/registry/AWS creds as their
  phases arrive), gated to non-fork builds.

### Phase 1 -- Close the cheap x86 parity gaps

- Wire the Rust `cargo test` coverage suites (qdb-core, qdb-parquet-meta, qdbr,
  parquet2) plus `install-llvm.yml` and the profraw->LCOV pipeline into the lint
  or a dedicated leg -- currently missing test coverage, low infra risk.
- Re-enable the jemalloc `LD_PRELOAD` coverage leg on the pinned image (libjemalloc
  baked in, no runtime lookup) and drive the 8-way coverage matrix to a green 8/8
  on `linux-large`.
- Finish the CoverageReports side: Rust LCOV -> Cobertura merge, then the
  cover-checker GitHub PR post behind the `GH_TOKEN` secret at the 50% threshold.

### Phase 2 -- Make sharding real and prove the dynamic backbone

- Run the bootstrap on a live PR: `fetch_timings.py` pulls last-green surefire
  XML with the REST secret, `generate.py` emits weighted, change-detected shards,
  static fallback verified on an induced error.
- Re-expand the merged functional legs into runtime-weighted shards so the
  cairo-is-the-critical-path imbalance is fixed with real data rather than the
  hand-tuned Azure include lists.
- Post GitHub commit statuses / a required check from the Buildkite build so PRs
  gate on it ([github source control](https://buildkite.com/docs/pipelines/source-control/github)).

### Phase 3 -- Multi-platform and the enterprise trigger

- Add the full macOS matrix (7 groups) on `macos-large`, accepting the higher
  per-minute cost; measure the monthly mac minute spend.
- Decide the enterprise trigger: a native `trigger` step if enterprise CI also
  moves to Buildkite, else a `command:` step re-issuing the ADO REST POST, with a
  GitHub status reported back.
- Decide arm64: upgrade to the Enterprise plan for hosted arm64, or keep an
  arm64 variant self-hosted.

### Phase 4 -- Release pipelines and the Windows/zfs decision

- Docker release: add registry login + `push=true` + digest capture + multi-arch
  manifest, tag/nightly/branch triggers.
- GitHub binary release (Linux half) and AMI publish, each behind their secrets.
- Windows and zfs: the two gaps with no hosted answer. Either stand up
  self-hosted Windows and zfs agents (partially reintroducing a fleet) or keep
  those specific legs on Azure/GHA long-term. This is a strategic decision, not a
  mechanical port, and should be made explicitly rather than by default.

### Phase 5 -- Decommission

- Only after Phases 1-4 run green on real PRs for a sustained period, and a
  real monthly-minute cost model confirms the economics, retire the Azure PR
  pipeline and the idle Hetzner fleet. Keep the GHA checks (1e) where they are.

---

## Sources

- Buildkite trigger step: https://buildkite.com/docs/pipelines/configure/step-types/trigger-step
- Buildkite command step (retry, soft_fail, timeout, if, parallelism, matrix, artifact_paths): https://buildkite.com/docs/pipelines/configure/step-types/command-step
- Managing step dependencies / depends_on: https://buildkite.com/docs/pipelines/configure/depends-on
- Test Engine test splitting: https://buildkite.com/docs/test-engine/test-splitting
- Test splitting configuration: https://buildkite.com/docs/test-engine/test-splitting/configuring
- Hosted agents (Linux) sizes, arch, timeout, concurrency: https://buildkite.com/docs/pipelines/hosted-agents/linux
- Hosted agents overview / caching: https://buildkite.com/docs/pipelines/hosted-agents
- Scheduled builds (pipeline-level, 10-min granularity, REST/UI/GraphQL): https://buildkite.com/docs/pipelines/configure/workflows/scheduled-builds
- Buildkite secrets (encrypted store, redaction, cluster scope): https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets
- Secrets overview: https://buildkite.com/docs/pipelines/security/secrets
- Managing pipeline secrets (external stores via plugins): https://buildkite.com/docs/pipelines/security/secrets/managing
- GitHub source control / commit statuses / checks: https://buildkite.com/docs/pipelines/source-control/github
- Notifications / annotations: https://buildkite.com/docs/pipelines/configure/notify
- Pricing (hosted Linux/Mac per-minute, plan tiers): https://buildkite.com/pricing/
