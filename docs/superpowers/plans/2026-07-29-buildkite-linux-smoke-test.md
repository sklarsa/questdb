# Buildkite Linux + macOS Smoke Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get one green Buildkite build running lint + tests + coverage against QuestDB `core` on Buildkite hosted agents, as an end-to-end smoke test in a personal fork.

**Architecture:** A single static `.buildkite/pipeline.yaml` declares parallel steps mapped to right-sized hosted queues (linux-small/medium/large, macos-large). A shared prelude script (`.buildkite/prelude.sh`) installs JDK 25, inits the client submodule, and exports common Maven flags so every step reuses identical setup. No dynamic pipeline, no change detection, no Reposilite/apt-mirror plumbing — Maven resolves from Central.

**Tech Stack:** Buildkite hosted agents, Bash, Maven (JDK 25, `-P local-client`), Cargo (Rust lint), JaCoCo (coverage).

## Global Constraints

- Build JDK: **25** (`core/pom.xml` `javac.target=25`). The local dev machine has JDK 11; core CANNOT be compiled locally. Compile/test validation happens ON Buildkite, not in this session.
- Client profile: **`-P local-client`** is required because `core/pom.xml` `questdb.client.version` is `1.3.6-SNAPSHOT`. The `java-questdb-client` submodule must be inited first (`git submodule update --init java-questdb-client`).
- Test legs pass `-DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false`.
- `build-web-console` profile is DROPPED (needs Node). `ServerMainTest` is excluded on the `other` leg to avoid the bundled-console dependency.
- Hosted queues (provisioned in org): `linux-small` (2vCPU/4GB, default), `linux-medium` (4/16), `linux-large` (8/32), `macos-medium` (6/28), `macos-large` (12/56). Target with `agents: { queue: <name> }`.
- Log messages / echoes: ASCII only.
- All work stays on the current `buildkite-test` branch. Commit frequently.
- Maven profiles confirmed present in `core/pom.xml`: `jacoco`, `qdbr-coverage`, `local-client`, `build-web-console`.
- Rust crates for lint: `core/rust/qdb-core`, `core/rust/qdb-parquet-meta`, `core/rust/qdbr`.

---

### Task 1: Shared prelude script

**Files:**
- Create: `.buildkite/prelude.sh`

**Interfaces:**
- Produces: a script sourced/run at the top of every step. Exports `JAVA_HOME` (JDK 25), inits the client submodule, exports `MVN_COMMON` (common Maven flags). Consumers rely on the name `.buildkite/prelude.sh` and the exported var `MVN_COMMON`.

- [ ] **Step 1: Write the prelude script**

```bash
#!/usr/bin/env bash
# Shared setup for every Buildkite step. Idempotent; safe to run per-step.
# Clean-room hosted agents: no Reposilite cache, no apt mirror. Maven resolves
# from Central. Installs JDK 25 on Linux; macOS agents ship a JDK we select.
set -euo pipefail

install_jdk_linux() {
  if [ -d /usr/lib/jvm/java-25-openjdk-amd64 ]; then
    export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
    return
  fi
  sudo apt-get update
  sudo apt-get install -y openjdk-25-jdk
  export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
}

select_jdk_macos() {
  # Buildkite macOS images ship multiple JDKs; pick 25.
  JH=$(/usr/libexec/java_home -v 25 2>/dev/null || true)
  if [ -z "$JH" ]; then
    echo "JDK 25 not found on macOS agent; installing via brew"
    brew install openjdk@25
    JH=$(/usr/libexec/java_home -v 25)
  fi
  export JAVA_HOME="$JH"
}

case "$(uname -s)" in
  Linux)  install_jdk_linux ;;
  Darwin) select_jdk_macos ;;
  *) echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
java -version

git submodule update --init java-questdb-client

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
```

- [ ] **Step 2: Make it executable and lint the shell**

Run: `chmod +x .buildkite/prelude.sh && bash -n .buildkite/prelude.sh && echo "shell syntax OK"`
Expected: `shell syntax OK` (no syntax errors). Note: we do NOT execute it locally — it installs JDK 25 and needs sudo/apt not present here.

- [ ] **Step 3: Commit**

```bash
git add .buildkite/prelude.sh
git commit -m "Add shared Buildkite prelude script"
```

---

### Task 2: Pipeline skeleton with the lint step

**Files:**
- Modify (replace): `.buildkite/pipeline.yaml`

**Interfaces:**
- Consumes: `.buildkite/prelude.sh` (Task 1), `MVN_COMMON`.
- Produces: a valid Buildkite pipeline with one `lint` step on `linux-small`. Later tasks append test/coverage steps to the same `steps:` list.

The lint step is the one whose commands we CAN validate locally (Rust + python), so it is the first real step.

- [ ] **Step 1: Write the pipeline skeleton**

```yaml
# Buildkite Linux + macOS smoke test for QuestDB core.
# Static pipeline on hosted agents (clean-room, Maven from Central).
# See docs/superpowers/specs/2026-07-29-buildkite-linux-smoke-test-design.md
steps:
  - label: ":lint-roller: lint"
    key: lint
    agents:
      queue: linux-small
    command: |
      source .buildkite/prelude.sh
      echo "--- unterminated log check"
      python3 find_unterminated_logs.py core/src --exclude=LogParanoiaTest.java
      echo "--- rust fmt + clippy"
      for crate in qdb-core qdb-parquet-meta qdbr; do
        ( cd core/rust/$crate && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings )
      done
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.buildkite/pipeline.yaml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 3: Validate the lint commands actually work locally**

These commands run against the real repo and do NOT need JDK 25, so run them here to prove the step will pass on Buildkite:

Run: `python3 find_unterminated_logs.py core/src --exclude=LogParanoiaTest.java && echo "log check OK"`
Expected: exits 0, `log check OK` (repo is clean on master).

Run: `for crate in qdb-core qdb-parquet-meta qdbr; do (cd core/rust/$crate && cargo fmt --check) || exit 1; done && echo "fmt OK"`
Expected: `fmt OK`. If any crate fails fmt, that is a real pre-existing issue — report it, do not "fix by reformatting" silently.

- [ ] **Step 4: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Replace hello-world Buildkite pipeline with lint step"
```

---

### Task 3: Bytecode-size check on the lint step

**Files:**
- Modify: `.buildkite/pipeline.yaml` (extend the `lint` step command)

**Interfaces:**
- Consumes: the compiled core JAR. The bytecode check needs a built JAR, so the lint step must compile core first (JDK 25, so this part is Buildkite-only).

- [ ] **Step 1: Append compile + bytecode-size to the lint step command**

Add to the `lint` step's `command:` block, after the rust loop:

```yaml
      echo "--- compile core (needed for bytecode check)"
      mvn $MVN_COMMON -pl core -am -DskipTests compile
      echo "--- bytecode size check"
      JAR_FILE=$(find core/target -maxdepth 1 -name "questdb-*.jar" ! -name "*-tests.jar" ! -name "*-sources.jar" ! -name "*-javadoc.jar" | head -1)
      if [ -z "$JAR_FILE" ]; then echo "No QuestDB JAR found"; exit 1; fi
      ./ci/check-bytecode-size.sh --jar "$JAR_FILE" --threshold 8000
```

Note: `compile` here produces classes but the bytecode script wants a JAR. If `compile` alone does not produce the JAR, change the goal to `package -DskipTests`. Decide on Buildkite by observing the `find` result; the fallback is `package`.

- [ ] **Step 2: Validate YAML still parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.buildkite/pipeline.yaml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Add compile + bytecode-size check to Buildkite lint step"
```

---

### Task 4: Linux test legs (griffin, cairo, other)

**Files:**
- Modify: `.buildkite/pipeline.yaml` (append three steps)

**Interfaces:**
- Consumes: `.buildkite/prelude.sh`, `MVN_COMMON`.
- Produces: three parallel test steps. `griffin` and `cairo` on `linux-large`, `other` on `linux-medium`. Each uploads JUnit XML as an artifact (feeds the future runtime-weighted split).

- [ ] **Step 1: Append the three test steps**

```yaml
  - label: ":coffee: test: griffin"
    key: test-griffin
    agents:
      queue: linux-large
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      mvn $MVN_COMMON clean test -Dtest.include='**/griffin/**'

  - label: ":coffee: test: cairo"
    key: test-cairo
    agents:
      queue: linux-large
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      mvn $MVN_COMMON clean test -Dtest.include='**/cairo/**'

  - label: ":coffee: test: other"
    key: test-other
    agents:
      queue: linux-medium
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      mvn $MVN_COMMON clean test \
        -Dtest.exclude='**/griffin/**,**/cairo/**,**/ServerMainTest.java'
```

- [ ] **Step 2: Validate YAML parses and step keys are unique**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.buildkite/pipeline.yaml'))
keys = [s.get('key') for s in d['steps'] if isinstance(s, dict)]
assert len(keys) == len(set(keys)), f"dup keys: {keys}"
print("YAML OK, keys:", keys)
PY
```
Expected: `YAML OK, keys: ['lint', 'test-griffin', 'test-cairo', 'test-other']`

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Add Linux griffin/cairo/other test legs to Buildkite pipeline"
```

---

### Task 5: Coverage leg (proof-of-path)

**Files:**
- Modify: `.buildkite/pipeline.yaml` (append one step)

**Interfaces:**
- Consumes: `.buildkite/prelude.sh`, `MVN_COMMON`.
- Produces: a `coverage` step on `linux-medium` that runs an instrumented test slice and produces a JaCoCo report artifact. This proves the coverage path is green; it is NOT the full 8-way matrix and does NOT post to GitHub.

- [ ] **Step 1: Append the coverage step**

```yaml
  - label: ":bar_chart: coverage (proof-of-path)"
    key: coverage
    agents:
      queue: linux-medium
    artifact_paths:
      - "core/target/site/jacoco/**/*"
      - "core/target/jacoco.exec"
    command: |
      source .buildkite/prelude.sh
      echo "--- pre-build core so coverage run has deps"
      mvn $MVN_COMMON -pl core -am -DskipTests install
      echo "--- instrumented test slice (std package) with jacoco"
      mvn $MVN_COMMON -f core/pom.xml test \
        -P jacoco,qdbr-coverage \
        -Dtest.include='**/std/**'
      echo "--- jacoco report"
      mvn $MVN_COMMON -f core/pom.xml jacoco:report || true
```

Note: `jacoco:report` may need the `jacoco` profile active to bind the goal; if it errors, the `-P jacoco` on the test run already writes `jacoco.exec`, and the report can be produced by the merge tooling later. The `|| true` keeps the smoke test green while still uploading `jacoco.exec`.

- [ ] **Step 2: Validate YAML parses, keys unique**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.buildkite/pipeline.yaml'))
keys = [s.get('key') for s in d['steps'] if isinstance(s, dict)]
assert len(keys) == len(set(keys)), f"dup keys: {keys}"
print("keys:", keys)
PY
```
Expected: keys include `coverage`.

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Add coverage proof-of-path leg to Buildkite pipeline"
```

---

### Task 6: macOS griffin leg

**Files:**
- Modify: `.buildkite/pipeline.yaml` (append one step)

**Interfaces:**
- Consumes: `.buildkite/prelude.sh` (its `Darwin` branch), `MVN_COMMON`.
- Produces: a `test-macos-griffin` step on `macos-large` running the same griffin shard as Linux, for cross-platform (ARM64) signal.

- [ ] **Step 1: Append the macOS step**

```yaml
  - label: ":apple: test: griffin (macos)"
    key: test-macos-griffin
    agents:
      queue: macos-large
    artifact_paths:
      - "core/target/surefire-reports/**/*.xml"
    command: |
      source .buildkite/prelude.sh
      mvn $MVN_COMMON clean test -Dtest.include='**/griffin/**'
```

- [ ] **Step 2: Validate YAML parses, all keys unique**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.buildkite/pipeline.yaml'))
keys = [s.get('key') for s in d['steps'] if isinstance(s, dict)]
assert len(keys) == len(set(keys)), f"dup keys: {keys}"
assert keys == ['lint','test-griffin','test-cairo','test-other','coverage','test-macos-griffin'], keys
print("all keys OK:", keys)
PY
```
Expected: `all keys OK: [...]`

- [ ] **Step 3: Commit**

```bash
git add .buildkite/pipeline.yaml
git commit -m "Add macOS griffin test leg to Buildkite pipeline"
```

---

### Task 7: End-to-end smoke run on Buildkite

**Files:** none (validation task)

**Interfaces:**
- Consumes: the whole pipeline.
- Produces: a real Buildkite build result and a list of what still needs wiring.

This is the ONLY task that proves the actual goal. It cannot run in the dev session; it needs the pushed branch and a Buildkite pipeline pointed at the fork.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin buildkite-test
```

- [ ] **Step 2: Trigger a Buildkite build**

In the Buildkite UI (or `bk build create` if the CLI is configured), run the pipeline against the `buildkite-test` branch of the fork.

- [ ] **Step 3: Observe results and record status**

Expected on a first fork run (partial-green is acceptable per the original ask):
- `lint` should go GREEN (commands validated locally in Tasks 2-3).
- Test legs compile core on JDK 25 and run their package subset.
- `coverage` uploads `jacoco.exec` even if `jacoco:report` is skipped.
- macOS leg runs griffin to completion on ARM64.

For any RED step, capture the failing command + log excerpt. Do NOT dismiss as "flaky/known" without evidence (per CLAUDE.md). Common first-run gaps to check explicitly:
- `sudo apt-get install openjdk-25-jdk` not available on the hosted image -> switch to a download (Temurin) or a preinstalled path.
- macOS `/usr/libexec/java_home -v 25` returns empty -> brew install path timing.
- `ServerMainTest` or other web-console-dependent tests surfacing on the `other` leg -> extend the exclude or add `-P build-web-console` to that leg only.

- [ ] **Step 4: Write findings to the spec's "Going forward" section**

Append a short "First smoke run results" subsection to `docs/superpowers/specs/2026-07-29-buildkite-linux-smoke-test-design.md` listing which legs went green, which need wiring, and the measured per-leg wall-clock (the baseline for future runtime-weighted sharding). Commit.

---

## Self-Review

**Spec coverage** (checked against `2026-07-29-buildkite-linux-smoke-test-design.md`):
- Lint (log check, rust fmt/clippy, bytecode size) -> Tasks 2, 3. Covered.
- griffin / cairo / other test legs on right-sized queues -> Task 4. Covered.
- Coverage proof-of-path on `**/std/**` + report -> Task 5. Covered.
- macOS griffin leg on macos-large -> Task 6. Covered.
- Drop Reposilite/apt-mirror/change-detection -> inherent (never added); prelude resolves from Central. Covered.
- ServerMainTest exclude default -> Task 4 `-Dtest.exclude`. Covered.
- JUnit XML artifact upload for future sharding baseline -> Tasks 4, 6 `artifact_paths`. Covered.
- e2e green build -> Task 7. Covered.
- Deliberately-cut items (arm64/zfs/graal, Windows, enterprise trigger, cover-checker posting, IntelliJ format, 8-way matrix) -> intentionally absent, documented in spec. No task needed.

**Placeholder scan:** No "TBD/TODO". The two `Note:` blocks (Task 3 compile-vs-package, Task 5 jacoco:report) give a concrete default + a concrete fallback, decided on real Buildkite output — not open-ended.

**Type/name consistency:** Step `key`s are consistent across tasks and asserted in Task 6 (`lint`, `test-griffin`, `test-cairo`, `test-other`, `coverage`, `test-macos-griffin`). `MVN_COMMON` and `.buildkite/prelude.sh` names are consistent across all tasks. Queue names match the Global Constraints table.
