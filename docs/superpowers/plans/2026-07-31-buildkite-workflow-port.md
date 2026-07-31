# Buildkite Workflow Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the remaining Azure CI workflows to Buildkite one at a time, breadth-first, each verified green on the `buildkite-test` fork branch, producing a scored Buildkite Friction Log.

**Architecture:** Extend the existing green static `.buildkite/pipeline.yaml` (build #24) by adding one workflow-step per chunk. Scheduled fuzz gets its own `pipeline.fuzz.yaml`. macOS gets a `macos-prelude.sh`. The dynamic pipeline generator (`generate.py`, change detection + weighted sharding) lands last, after real per-class timing data has accrued from earlier chunks' surefire XML artifacts.

**Tech Stack:** Buildkite hosted agents (linux-small/medium/large, macos-large), custom agent image (`.buildkite/Dockerfile`: JDK 25 + Maven + Rust), bash prelude, Maven (`-P local-client`), Python 3 stdlib (generator), Buildkite REST API (verification loop + generator timing pull).

## Global Constraints

- Target platform this round: Linux x86_64 hosted agents; macOS ARM64 for chunk 6 only. No arm64-linux / zfs / graal / Windows.
- Maven resolves from Central only. No Reposilite (`maven.internal:8081`), no Hetzner apt mirror, no self-hosted pool plumbing.
- Every step sources `.buildkite/prelude.sh` first (installs/selects JDK 25, Maven, Rust; builds + installs the `java-questdb-client` -SNAPSHOT with its native `libquestdb.so`; exports `MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"`).
- Log/echo text is strictly ASCII (QuestDB log-infra rule; also keeps Buildkite log rendering clean).
- No external publishing: docker builds but does not push; coverage is computed/artifact'd but not posted to any PR.
- Verification is a real Buildkite build, not a local test run. "Green" means the build passes AND logs show the leg did real work (not a silent no-op / skipped tests).
- Buildkite command-wrapper gotchas already learned (carry forward): a bare `*` glob and `find -name` can come back empty inside an inline `command:` block, so globbing that must work belongs inside a sourced `.sh`; a plain shell var set on one line can read empty on the next line — keep set-and-use on one line; `$MVN_COMMON` survives across lines only because `prelude.sh` exports it.
- Buildkite artifact hard limit: 5000 files per job. Report trees with thousands of small files (JaCoCo HTML) must be compressed to a single archive (`.tgz`, via `artifacts#vX` plugin `compressed:`) before upload — `.tgz` not `.zip` (zip binary absent on plain agents).

---

## Verification loop (applies to every chunk)

Each chunk's "run the test" steps use this loop. Token: `~/.buildkite-token`. Org/pipeline: `questdb-1/questdb`, branch `buildkite-test`.

- Trigger a build (returns build number):
```bash
TOKEN=$(cat ~/.buildkite-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "https://api.buildkite.com/v2/organizations/questdb-1/pipelines/questdb/builds" \
  -d '{"commit":"HEAD","branch":"buildkite-test","message":"<chunk> verify"}' \
  | python3 -c "import sys,json; b=json.load(sys.stdin); print(b.get('number'), b.get('web_url'))"
```
- Poll a build's job states:
```bash
TOKEN=$(cat ~/.buildkite-token); N=<build-number>
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.buildkite.com/v2/organizations/questdb-1/pipelines/questdb/builds/$N" \
  | python3 -c "import sys,json;b=json.load(sys.stdin);print(b['state']);[print(' ',j.get('state'),j.get('name')) for j in b.get('jobs',[]) if j.get('type')=='script']"
```
- Read a failed job's log (get `job_id` from the poll's raw JSON `jobs[].id`):
```bash
TOKEN=$(cat ~/.buildkite-token); N=<build-number>; JOB=<job-id>
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.buildkite.com/v2/organizations/questdb-1/pipelines/questdb/builds/$N/jobs/$JOB/log" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['content'])" | tail -100
```

Prefer waiting on Buildkite via the background/Monitor mechanism rather than a foreground sleep. Report to the user per chunk-complete or per real blocker, not per red build.

---

## Task 1: Compat + javadoc legs

**Files:**
- Modify: `.buildkite/pipeline.yaml` (add two steps)

**Interfaces:**
- Consumes: `.buildkite/prelude.sh` (`MVN_COMMON`, client native build already done there).
- Produces: two new pipeline steps keyed `compat` and `javadoc`. No cross-step data.

Azure source of truth:
- Javadoc (`aux-job.yml:47-56`): `mvn compile javadoc:javadoc -DskipTests -P javadoc -P qdbr-release`.
- Compat (`compat-steps.yml:65-82` + `test-pipeline.yml`): `mvn clean test -Dtest.include=**/compat/**,**/cliutil/**` over the full reactor, `-Dout=ci/qlog.conf`, `-DfailIfNoTests=false`.

- [ ] **Step 1: Add the javadoc step to `.buildkite/pipeline.yaml`**

Append after the coverage step:

```yaml
  - label: ":memo: javadoc"
    key: javadoc
    agents:
      queue: linux-medium
    command: |
      source .buildkite/prelude.sh
      echo "--- javadoc"
      mvn $MVN_COMMON compile javadoc:javadoc -DskipTests -P javadoc -P qdbr-release
```

- [ ] **Step 2: Add the compat step to `.buildkite/pipeline.yaml`**

Append after the javadoc step. Uploads surefire XML like the other test legs so its per-class timings feed chunk 8:

```yaml
  - label: ":handshake: compat"
    key: compat
    agents:
      queue: linux-medium
    artifact_paths:
      - "compat/target/surefire-reports/**/*.xml"
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      echo "--- compat + cliutil tests"
      mvn $MVN_COMMON clean test \
        -Dtest.include='**/compat/**,**/cliutil/**' \
        -Dout=$PWD/ci/qlog.conf
```

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Add compat and javadoc Buildkite legs"
```

- [ ] **Step 4: Push and trigger a build**

```bash
git push origin buildkite-test
# then trigger via the verification-loop POST above
```

- [ ] **Step 5: Poll until the build finishes; confirm `compat` and `javadoc` are green**

Expected: both new jobs `passed`. Read the compat log and confirm it ran actual compat tests (surefire "Tests run: N" with N>0), not a no-op. Read the javadoc log and confirm `javadoc:javadoc` executed (BUILD SUCCESS, javadoc output emitted). If red, pull the failed job log, fix, re-push, re-trigger.

- [ ] **Step 6: Record the Friction Log row (chunk 1) in the design doc**

Fill row 1 of the table in `docs/superpowers/specs/2026-07-31-buildkite-workflow-port-design.md`: Azure mechanism (Maven tasks in aux-job/compat-steps), Buildkite mapping (two inline steps), what fought back + fix, score. Commit the doc update.

---

## Task 2: jemalloc coverage leg

**Files:**
- Modify: `.buildkite/pipeline.yaml` (add one step)
- Modify: `.buildkite/prelude.sh` (add a `ensure_jemalloc()` fallback installer, called only by this leg via an env guard OR a separate helper — see step 1)

**Interfaces:**
- Consumes: `MVN_COMMON`, the `jacoco,qdbr-coverage` Maven profiles (already used by the existing coverage step), the JaCoCo `.tgz` compression pattern from the existing coverage step.
- Produces: a pipeline step keyed `coverage-jemalloc` that runs an instrumented test slice under `LD_PRELOAD=<libjemalloc>`.

Azure source: `self-hosted-cover-jobs.yml` — coverage runs `LD_PRELOAD` jemalloc to exercise the native allocator path under instrumentation. Probe: does `LD_PRELOAD` take effect on a hosted agent.

- [ ] **Step 1: Add a jemalloc locator to `.buildkite/prelude.sh`**

Add a function that finds or installs libjemalloc and echoes its path (does not export globally; the step captures it). ASCII-only logs:

```bash
locate_jemalloc() {
  # Echo the path to libjemalloc.so, installing it if missing. Used only by the
  # jemalloc coverage leg to LD_PRELOAD the native allocator under instrumentation.
  local p
  p=$(ldconfig -p 2>/dev/null | grep -m1 'libjemalloc\.so' | awk '{print $NF}')
  if [ -z "$p" ] && command -v apt-get >/dev/null 2>&1; then
    echo "jemalloc not present; installing libjemalloc2" >&2
    sudo apt-get update >&2 && sudo apt-get install -y --no-install-recommends libjemalloc2 >&2
    p=$(ldconfig -p 2>/dev/null | grep -m1 'libjemalloc\.so' | awk '{print $NF}')
  fi
  echo "$p"
}
```

- [ ] **Step 2: Add the jemalloc coverage step to `.buildkite/pipeline.yaml`**

```yaml
  - label: ":pill: coverage (jemalloc LD_PRELOAD)"
    key: coverage-jemalloc
    agents:
      queue: linux-medium
    plugins:
      - artifacts#v1.9.4:
          upload:
            - "core/target/site/jacoco"
          compressed: jacoco-jemalloc.tgz
    command: |
      source .buildkite/prelude.sh
      JEM=$(locate_jemalloc)
      echo "--- jemalloc path: ${JEM:-NONE}"
      test -n "$JEM" || { echo "libjemalloc not found"; exit 1; }
      mvn $MVN_COMMON -pl core -am -DskipTests install
      echo "--- instrumented std slice under jemalloc"
      LD_PRELOAD="$JEM" mvn $MVN_COMMON -f core/pom.xml test \
        -P jacoco,qdbr-coverage -Dtest.include='**/std/**'
      mvn $MVN_COMMON -f core/pom.xml jacoco:report || true
```

- [ ] **Step 3: Commit, push, trigger, poll**

Expected: job `passed`. Confirm from the log that `jemalloc path:` printed a real `.so` path and that tests ran under it (the leg must fail loudly if libjemalloc is absent, per the `test -n` guard). Fix + re-trigger on red.

- [ ] **Step 4: Record Friction Log row (chunk 2), commit doc.**

---

## Task 3: IntelliJ format check

**Files:**
- Modify: `.buildkite/pipeline.yaml` (add one step)

**Interfaces:**
- Consumes: `.buildkite/prelude.sh` (JDK 25 for the format run).
- Produces: a pipeline step keyed `format` that downloads pinned IntelliJ, runs `idea.sh format`, and fails on any diff.

Azure source: `java-lint.yml:4-42`. Pinned IntelliJ `idea-2026.1.4.tar.gz` (~2GB). Probe: hosted-agent tool-cache pain (re-download every run).

- [ ] **Step 1: Add the format step to `.buildkite/pipeline.yaml`**

```yaml
  - label: ":art: format (intellij)"
    key: format
    agents:
      queue: linux-medium
    command: |
      source .buildkite/prelude.sh
      IDEA_ROOT="$PWD/.ci/intellij"
      rm -rf "$IDEA_ROOT"; mkdir -p "$IDEA_ROOT"
      echo "--- download pinned IntelliJ (2GB, no persistent agent tool cache)"
      wget -q "https://download.jetbrains.com/idea/idea-2026.1.4.tar.gz" -O intellij.tar.gz
      tar xzf intellij.tar.gz -C "$IDEA_ROOT"; rm intellij.tar.gz
      ( cd "$IDEA_ROOT" && ln -s idea-* idea )
      echo "--- apply formatting in place"
      "$IDEA_ROOT/idea/bin/idea.sh" format -s .idea/codeStyles/Project.xml -m "*.java" -r .
      echo "--- reset submodules touched by the formatter"
      git submodule foreach --quiet 'git checkout -- . 2>/dev/null; git clean -fd 2>/dev/null' || true
      echo "--- fail if the formatter changed anything"
      git status -s
      git diff --exit-code
```

- [ ] **Step 2: Commit, push, trigger, poll**

Expected: job `passed` on an already-formatted tree (master is formatted, so `git diff --exit-code` returns 0). Confirm from the log that IntelliJ actually downloaded and `format` ran (not skipped). Note the download time in the Friction Log. Fix + re-trigger on red. NOTE: if the leg reports real formatting diffs, that is a genuine finding (the fork branch drifted) — surface it, do not auto-reformat unless trivially the pin.

- [ ] **Step 3: Record Friction Log row (chunk 3), commit doc.**

---

## Task 4: Scheduled fuzz pipeline

**Files:**
- Create: `.buildkite/pipeline.fuzz.yaml`

**Interfaces:**
- Consumes: `.buildkite/prelude.sh`.
- Produces: a standalone pipeline definition run on a schedule (cron), not part of the PR pipeline.

Azure source: `test-fuzz.yml` — `schedules: cron "*/15 * * * *"` on master, `-Dtest.include=%regex[.*Fuzz.*class]`, 60m timeout. Probe: Buildkite scheduled builds + long randomized jobs. Note: this needs a **separate Buildkite pipeline** pointed at this YAML with a schedule configured (via API or UI). Buildkite schedules are pipeline settings, not in-YAML — so this task also creates/configures that schedule via the REST API.

- [ ] **Step 1: Create `.buildkite/pipeline.fuzz.yaml`**

```yaml
# Scheduled fuzz run. Mirrors Azure ci/test-fuzz.yml (cron every 15 min on
# master). Runs the Fuzz-matching test classes across the full reactor on a
# large Linux agent. Not part of the per-PR pipeline.
steps:
  - label: ":game_die: fuzz"
    key: fuzz
    agents:
      queue: linux-large
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      echo "--- fuzz test classes (full reactor)"
      mvn $MVN_COMMON clean test -Dtest.include='**/*Fuzz*'
```

- [ ] **Step 2: Decide the fuzz pipeline's home and configure its schedule**

Buildkite runs a schedule against a *pipeline*, and the pipeline points at a YAML path. Two viable options — pick per what the org allows:
  (a) A second Buildkite pipeline (e.g. `questdb-fuzz`) whose steps do `buildkite-agent pipeline upload .buildkite/pipeline.fuzz.yaml`, with a schedule attached.
  (b) The existing pipeline's build config selects the fuzz YAML when triggered by a schedule (via `BUILDKITE_SOURCE == "schedule"` branch in an upload step).
Default to (a) for isolation. Create the schedule via REST:

```bash
TOKEN=$(cat ~/.buildkite-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "https://api.buildkite.com/v2/organizations/questdb-1/pipelines/<fuzz-pipeline>/schedules" \
  -d '{"cronline":"*/15 * * * *","branch":"master","message":"scheduled fuzz","commit":"HEAD"}'
```

For the fork eval, a less aggressive cronline (e.g. hourly) is acceptable to conserve agents — note the deviation from Azure's 15-min in the Friction Log.

- [ ] **Step 3: Trigger one manual fuzz build to verify the YAML runs green, then confirm the schedule exists**

Expected: a manual build of the fuzz pipeline passes and the log shows Fuzz classes ran (Tests run: N>0). List schedules via `GET .../schedules` and confirm one is present + enabled.

- [ ] **Step 4: Record Friction Log row (chunk 4), commit doc.**

---

## Task 5: Docker build (no push)

**Files:**
- Modify: `.buildkite/pipeline.yaml` (add one step)

**Interfaces:**
- Consumes: the repo's production Dockerfile (find it: likely `core/Dockerfile` or repo-root; confirm before writing the step).
- Produces: a pipeline step keyed `docker-build` that builds the image(s) but never pushes.

Azure source: `docker-release-pipeline.yml` — multi-arch buildx. Probe: docker-in-Buildkite on hosted agents (is the daemon present / does buildx work), without registry creds.

- [ ] **Step 1: Locate the production Dockerfile and the build args the release pipeline uses**

Read `ci/docker-release-pipeline.yml` for the `docker buildx build` invocation, image name, platforms, and build context. Identify the Dockerfile path. (Do not assume — grep the repo.)

- [ ] **Step 2: Add the docker-build step to `.buildkite/pipeline.yaml`**

Skeleton (fill Dockerfile path / context / platforms from step 1). Build only, `--load` or no `--push`; single-arch first if buildx multi-arch needs QEMU that the hosted agent lacks (note that in the Friction Log):

```yaml
  - label: ":docker: docker build (no push)"
    key: docker-build
    agents:
      queue: linux-medium
    command: |
      set -euo pipefail
      echo "--- docker + buildx availability"
      docker version
      docker buildx version || echo "buildx not present"
      echo "--- build image (no push)"
      docker build -f <DOCKERFILE_PATH> -t questdb-ci:local <CONTEXT>
```

- [ ] **Step 3: Commit, push, trigger, poll**

Expected: job `passed`; log shows `docker version` succeeded (daemon present) and an image built (`Successfully tagged` / buildx export). If the hosted agent has no docker daemon, that is a real blocker to surface (may need a docker-enabled queue or the docker plugin) — record it and report back rather than forcing it.

- [ ] **Step 4: Record Friction Log row (chunk 5), commit doc.**

---

## Task 6: macOS griffin shard

**Files:**
- Create: `.buildkite/macos-prelude.sh`
- Modify: `.buildkite/pipeline.yaml` (add one step targeting `macos-large`)

**Interfaces:**
- Consumes: nothing from Linux prelude (macOS toolchain differs — brew JDK, no apt).
- Produces: `macos-prelude.sh` exporting the same `MVN_COMMON` contract as `prelude.sh`, plus a `test-macos-griffin` step.

Azure source: `test-hosted-pipeline.yml` + `hosted-jobs.yml` (mac path). Probe: macOS ARM64 agent + toolchain (brew JDK 25, native client build via cmake, no nasm on arm).

- [ ] **Step 1: Create `.buildkite/macos-prelude.sh`**

Mirror `prelude.sh`'s contract on macOS: select/install JDK 25 (prefer preinstalled, else `brew install openjdk@25` and symlink), ensure Maven (`brew install maven` if absent), ensure cmake (`brew install cmake`), build+install the `java-questdb-client` -SNAPSHOT and its native lib for `darwin-aarch64`, export the same `MVN_COMMON`. ASCII logs. Keep set-and-use of shell vars on one line per the wrapper gotcha. (Write the concrete script during execution; it parallels `prelude.sh` function-for-function with brew swapped for apt and `darwin-aarch64` as the native resource dir.)

- [ ] **Step 2: Add the macOS griffin step to `.buildkite/pipeline.yaml`**

```yaml
  - label: ":apple: test: griffin (macos)"
    key: test-griffin-macos
    agents:
      queue: macos-large
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/macos-prelude.sh
      mvn $MVN_COMMON clean test -Dtest.include='**/griffin/**'
```

- [ ] **Step 3: Commit, push, trigger, poll**

Expected: job `passed` on `macos-large`. Confirm from the log: JDK 25 selected (brew or preinstalled), native `libquestdb.dylib` built for `darwin-aarch64`, griffin tests ran (Tests run: N>0). If the `macos-large` queue has no agents in the trial, that is a real blocker — surface it and report back. Fix macOS toolchain issues + re-trigger.

- [ ] **Step 4: Record Friction Log row (chunk 6), commit doc.**

---

## Task 7: Coverage matrix (8-way) + report merge

**Files:**
- Modify: `.buildkite/pipeline.yaml` (replace the single proof-of-path coverage step with a matrix + a merge step)

**Interfaces:**
- Consumes: `MVN_COMMON`, `jacoco,qdbr-coverage` profiles, the `.tgz` compression pattern, Buildkite `matrix:` on a step, `depends_on` for the merge, the artifacts plugin to pass `jacoco.exec` between steps.
- Produces: 8 coverage shards + one `coverage-merge` step that merges JaCoCo exec files and Rust LCOV into a combined report (computed, not posted).

Azure source: `self-hosted-cover-jobs.yml` + `ci/jacoco-merge.xml` + `ci/merge_lcov_paths.py` + CoverageReports stage. The 8 legs: griffin-root, griffin-sub, fuzz1, fuzz2, cairo-root, cairo-sub, pgwire, other.

- [ ] **Step 1: Enumerate the 8 shards' include/exclude patterns from Azure**

Read `self-hosted-cover-jobs.yml` and the coverage matrix in `test-pipeline.yml`/`steps.yml` to copy the exact `-Dtest.include`/`-Dtest.exclude` per shard verbatim. Record them in a comment block in the pipeline.

- [ ] **Step 2: Replace the proof-of-path coverage step with a matrix step**

Use Buildkite `matrix:` to fan out the 8 shards; each runs its instrumented slice with `-P jacoco,qdbr-coverage`, LD_PRELOAD jemalloc (reuse `locate_jemalloc` from Task 2), and uploads its `jacoco.exec` (named per-shard) as an artifact. Skeleton:

```yaml
  - label: ":bar_chart: coverage {{matrix}}"
    key: coverage
    agents:
      queue: linux-medium
    matrix:
      - "griffin-root"
      - "griffin-sub"
      - "fuzz1"
      - "fuzz2"
      - "cairo-root"
      - "cairo-sub"
      - "pgwire"
      - "other"
    artifact_paths:
      - "core/target/jacoco-{{matrix}}.exec"
    command: |
      source .buildkite/prelude.sh
      JEM=$(locate_jemalloc)
      # map {{matrix}} -> include/exclude (case statement, patterns from step 1)
      ...
      LD_PRELOAD="$JEM" mvn $MVN_COMMON -f core/pom.xml test -P jacoco,qdbr-coverage <includes>
      cp core/target/jacoco.exec core/target/jacoco-{{matrix}}.exec
```

- [ ] **Step 3: Add the merge step**

```yaml
  - label: ":bar_chart: coverage merge"
    key: coverage-merge
    depends_on: coverage
    agents:
      queue: linux-medium
    plugins:
      - artifacts#v1.9.4:
          download: "core/target/jacoco-*.exec"
      - artifacts#v1.9.4:
          upload: "core/target/site/jacoco-merged"
          compressed: jacoco-merged.tgz
    command: |
      source .buildkite/prelude.sh
      echo "--- merge jacoco exec files (ci/jacoco-merge.xml)"
      mvn $MVN_COMMON -f ci/jacoco-merge.xml verify || \
        mvn $MVN_COMMON org.jacoco:jacoco-maven-plugin:merge org.jacoco:jacoco-maven-plugin:report
      echo "--- (fork eval) coverage computed, NOT posted to any PR"
```

Adjust the exact merge invocation to whatever `ci/jacoco-merge.xml` expects (read it in step 1). Rust LCOV merge (`ci/merge_lcov_paths.py`) is included only if a coverage shard emitted LCOV; otherwise note it as deferred in the Friction Log.

- [ ] **Step 4: Commit, push, trigger, poll**

Expected: 8 coverage jobs + 1 merge job all `passed`. Confirm the merge log shows exec files downloaded and a combined report produced. No PR posting (log must state it was skipped). Fix + re-trigger on red.

- [ ] **Step 5: Record Friction Log row (chunk 7), commit doc.**

---

## Task 8: Dynamic pipeline generator (change detection + weighted sharding)

**Files:**
- Create: `.buildkite/generate.py`
- Create: `.buildkite/test_generate.py`
- Modify: `.buildkite/pipeline.yaml` -> becomes a thin bootstrap that runs `generate.py | buildkite-agent pipeline upload`

**Interfaces:**
- Consumes: Buildkite REST API (pull last green master build's surefire artifacts), `git diff --name-only origin/master...HEAD` (change detection), the per-leg command templates from the static pipeline.
- Produces:
  - `load_timings(xml_paths) -> dict[str, float]`: class FQN -> seconds, summed across duplicate entries.
  - `bin_pack(classes, timings, n_shards) -> list[list[str]]`: greedy longest-processing-time-first; unknown classes get the median of known timings.
  - `changed_paths(base_ref) -> set[str]` and `select_shards(changed) -> set[str]`: map changed files to the shard groups that must run.
  - `render_pipeline(shards, changed) -> str`: emit Buildkite YAML to stdout.
  - `main()`: orchestrates; on ANY exception prints the static fallback pipeline and exits 0 (never fails the build).

This is the one task with true unit-test TDD. Only build it after chunks 1-7 have accrued timing data.

- [ ] **Step 1: Write failing test for `bin_pack` balance**

```python
# .buildkite/test_generate.py
import generate

def test_bin_pack_balances_by_time():
    classes = [f"C{i}" for i in range(8)]
    timings = {"C0":100,"C1":90,"C2":80,"C3":70,"C4":60,"C5":50,"C6":40,"C7":30}
    shards = generate.bin_pack(classes, timings, 4)
    loads = [sum(timings[c] for c in s) for s in shards]
    assert max(loads) - min(loads) <= 30  # LPT keeps shards within one item's weight
    assert sorted(c for s in shards for c in s) == sorted(classes)  # no class lost/dup
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd .buildkite && python3 -m unittest test_generate -v`
Expected: FAIL (module/function missing).

- [ ] **Step 3: Implement `bin_pack` (LPT greedy)**

```python
def bin_pack(classes, timings, n_shards):
    known = [t for t in timings.values() if t > 0]
    median = sorted(known)[len(known)//2] if known else 1.0
    weighted = sorted(classes, key=lambda c: timings.get(c, median), reverse=True)
    shards = [[] for _ in range(n_shards)]
    loads = [0.0] * n_shards
    for c in weighted:
        i = loads.index(min(loads))
        shards[i].append(c)
        loads[i] += timings.get(c, median)
    return shards
```

- [ ] **Step 4: Run tests, verify pass.** `python3 -m unittest test_generate -v` -> PASS.

- [ ] **Step 5: Write failing test for median fallback on unknown classes**

```python
def test_unknown_class_gets_median():
    classes = ["A","B","NEW"]
    timings = {"A":10, "B":30}   # NEW unknown -> median of {10,30} = 30 (upper-median)
    shards = generate.bin_pack(classes, timings, 2)
    assert sorted(c for s in shards for c in s) == ["A","B","NEW"]
    # NEW must not all-collapse onto an empty shard as weight 0
    loads = [sum(timings.get(c, 30) for c in s) for s in shards]
    assert min(loads) > 0
```

- [ ] **Step 6: Run (should pass with the median already in `bin_pack`); if not, fix.**

- [ ] **Step 7: Write failing test for `load_timings` parsing surefire XML**

```python
def test_load_timings_sums_time(tmp_path=None):
    import tempfile, os, textwrap
    d = tempfile.mkdtemp()
    p = os.path.join(d, "TEST-io.questdb.test.Foo.xml")
    open(p,"w").write('<testsuite name="io.questdb.test.Foo" time="12.5"></testsuite>')
    t = generate.load_timings([p])
    assert t["io.questdb.test.Foo"] == 12.5
```

- [ ] **Step 8: Run it, verify fail, implement `load_timings`**

```python
import xml.etree.ElementTree as ET
def load_timings(xml_paths):
    out = {}
    for p in xml_paths:
        try:
            root = ET.parse(p).getroot()
        except ET.ParseError:
            continue
        name = root.get("name"); t = root.get("time")
        if name and t:
            out[name] = out.get(name, 0.0) + float(t)
    return out
```

- [ ] **Step 9: Run tests, verify pass.**

- [ ] **Step 10: Write failing test for `select_shards` change detection**

```python
def test_docs_only_change_selects_no_test_shards():
    assert generate.select_shards({"docs/x.md", "README.md"}) == set()
def test_core_change_selects_test_shards():
    s = generate.select_shards({"core/src/main/java/io/questdb/cairo/X.java"})
    assert "test" in "".join(s).lower() or len(s) > 0
```

- [ ] **Step 11: Implement `changed_paths` + `select_shards`**

```python
import subprocess
def changed_paths(base_ref="origin/master"):
    out = subprocess.run(["git","diff","--name-only",f"{base_ref}...HEAD"],
                         capture_output=True, text=True).stdout
    return {l for l in out.splitlines() if l.strip()}
def select_shards(changed):
    # Docs/CI-only diffs skip the test shards. Any source change runs them all
    # (shard-level granularity; class-level pruning is a later refinement).
    src = {p for p in changed if p.startswith(("core/","compat/")) and not p.endswith(".md")}
    return {"test"} if src else set()
```

- [ ] **Step 12: Run tests, verify pass.**

- [ ] **Step 13: Implement `render_pipeline` + `main` with static fallback**

`render_pipeline` emits the weighted test shards (from `bin_pack`) plus the always-run legs (lint). `main` pulls the last green master build's surefire artifacts via REST (reuse the verification-loop pull pattern), computes timings, reads changed paths, and prints YAML; wrap the whole body in try/except that prints the committed static pipeline and exits 0 on any error. Add a test that `main` never raises on empty input.

- [ ] **Step 14: Convert `.buildkite/pipeline.yaml` to a bootstrap**

The committed `pipeline.yaml` becomes:
```yaml
steps:
  - label: ":pipeline: generate"
    command: python3 .buildkite/generate.py | buildkite-agent pipeline upload
```
Keep the current static pipeline content as `.buildkite/pipeline.static.yaml` for the fallback path.

- [ ] **Step 15: Commit, push, trigger, poll**

Expected: bootstrap runs, uploads a dynamic pipeline whose test shards are balanced by wall-time (verify the cairo-heavy classes are spread, not all on one shard) and whose shard count matches the diff (a docs-only test commit should skip test shards). Confirm green end to end.

- [ ] **Step 16: Record Friction Log row (chunk 8), commit doc. Write the final Buildkite-vs-Azure evaluation summary section in the design doc.**

---

## Self-review notes

- Spec coverage: chunks 1-8 in the spec map 1:1 to Tasks 1-8. The Friction Log (spec's eval artifact) is updated in the final step of every task.
- Placeholder scan: Tasks 5-7 intentionally defer exact Dockerfile path / coverage-shard patterns / merge invocation to a first execution step that reads the Azure source, because those values must be copied verbatim from files rather than guessed — each such step names the exact file to read. Task 6's macOS prelude is described as "parallel to prelude.sh function-for-function"; the concrete script is written at execution because it is a mechanical apt->brew translation of an existing, read file.
- Type consistency: `locate_jemalloc` (Task 2) is reused by name in Task 7; `MVN_COMMON` contract is identical across Linux and macOS preludes; `bin_pack`/`load_timings`/`select_shards`/`render_pipeline`/`main` signatures in Task 8 match their tests.
