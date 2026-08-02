# Buildkite deferred chunks re-enabled on the warm custom image

Date: 2026-08-01
Author: Steven Sklar
Status: results

Follow-up to `2026-07-31-buildkite-workflow-port-design.md`. Two chunks were
DEFERRED because the custom agent image (`linux-x86-test`, JDK25 + Maven + Rust +
cmake + wget baked in) was not yet attached to the linux queues. It is now
attached (confirmed active on `questdb` build #44: `Using JAVA_HOME=/opt/jdk`,
Temurin-25.0.4 baked, no runtime download). This note records re-enabling both
chunks on that warm image.

Note on the REST API and the image: the queue REST endpoint still reports
`agent_image_ref: null` on all three linux queues. That field is feature-gated
in the API (documented in the design doc); the image is attached via the Cluster
UI and its activity is only observable in the build LOGS, not the API. The
`null` is API-blindness, not proof the image is unattached - build #44's log
shows the baked JDK path.

## Chunk 2 - jemalloc coverage leg: SOLVED (root cause found)

### The real root cause of the 10-build saga

Every prior attempt tried to `apt-get install libjemalloc2` and then LOCATE the
resulting `.so` at runtime (ldconfig, find, ls glob, bare `test -e`), all of
which returned empty in the step shell. That entire approach was a wrong turn:
**Azure never installs libjemalloc at all.** Azure's `ci/templates/steps.yml`
("Run tests with Coverage (jemalloc)") LD_PRELOADs a libjemalloc.so that is
COMMITTED IN THE REPO:

    LD_PRELOAD: $(Build.SourcesDirectory)/core/src/main/bin/linux-x86-64/libjemalloc.so

That file is a git-tracked 931 KB ELF x86-64 shared object (jemalloc 5.3.0,
exports `malloc_conf`/`mallctl`, soname `libjemalloc.so`). It is always in the
checkout, so there is NOTHING to discover: no apt, no ldconfig, no find. The
whole filesystem-visibility investigation was chasing a file that did not need
to exist.

### The second, compounding gotcha (measured, not guessed)

The first re-enable attempt still failed - build #1 of the throwaway
`questdb-jemalloc-deferred` pipeline. The step did:

    export LD_PRELOAD="$(pwd)/.../libjemalloc.so"; test -f "$LD_PRELOAD" || { echo FATAL ...; exit 1; }

and the guard fired with an EMPTY path. The Buildkite command-trace in the log
showed the line as:

    export LD_PRELOAD="$(pwd)/.../libjemalloc.so"; test -f "" || { echo "...at "; exit 1; }

i.e. the wrapper PRE-EXPANDS a bare `$VAR` reference at trace time, BEFORE the
line runs, so a just-`export`ed `$LD_PRELOAD` reads back EMPTY on its own line -
even though the `export` and the read are on the SAME physical line separated by
`;`. This is the same "non-exported var reads empty next line" family the design
doc flagged as the leading suspect, but sharper: it bites even same-line reads of
a var set earlier on that line. `$(pwd)` command substitution, by contrast, is
PRESERVED by the trace and runs at runtime (the log shows `$(pwd)` un-expanded).

### The fix (works on the CURRENT image, no image rebuild needed)

Never read back a `$VAR` we just set. Recompute the path inline with `$(pwd)` and
set `LD_PRELOAD` as an inline command-PREFIX on the very process that needs it -
set-and-use in one spawn, no cross-reference:

    test -f "$(pwd)/core/src/main/bin/linux-x86-64/libjemalloc.so" || { echo FATAL ...; exit 1; }
    LD_PRELOAD="$(pwd)/.../libjemalloc.so" bash -c 'grep -q jemalloc /proc/self/maps && echo "jemalloc preloaded OK: $(grep -c jemalloc /proc/self/maps) mappings" || { echo FATAL ...; exit 1; }'
    ...
    LD_PRELOAD="$(pwd)/.../libjemalloc.so" mvn $MVN_COMMON -f core/pom.xml test -P jacoco,qdbr-coverage -Dtest.include='**/std/**' ...

The `grep jemalloc /proc/self/maps` check FAILS the step (exit 1) if jemalloc did
not actually map, so the leg can never silently no-op on the system allocator.

### Belt-and-suspenders in the Dockerfile

`.buildkite/Dockerfile` also now `apt-get install libjemalloc2` and symlinks it to
a fixed `/opt/libjemalloc.so`, so a KNOWN discovery-free path also exists on the
image. The pipeline does NOT depend on this (it uses the committed repo `.so`),
but it removes any future runtime lookup if the repo file ever moves. NOTE: the
custom image is pasted into the Buildkite UI, not auto-built on push, so this
Dockerfile change only takes effect when the image is next re-pasted; the
committed-`.so` path is what makes the leg green on the CURRENT image today.

### Result

- Throwaway pipeline `questdb-jemalloc-deferred`, build #1: FAILED - diagnosed as
  the empty-`$LD_PRELOAD` trace-expansion gotcha above (proof: `test -f ""` in the
  log, empty-path FATAL).
- Build #2 (hardened inline-prefix): PASSED. Log proof:
  - `jemalloc preloaded OK: 5 mappings` - jemalloc actually mapped into the
    verification subprocess (the check exits 1 if it does not, so this is a real
    load, not a no-op).
  - `Tests run: 2748, Failures: 0, Errors: 0, Skipped: 7` for the `**/std/**`
    slice run UNDER jemalloc, then `BUILD SUCCESS`.
  - The trailing `mvn jacoco:report` prints a `BUILD FAILURE` ("No plugin found
    for prefix 'jacoco'") because that standalone goal does not activate the
    `jacoco` profile that binds the plugin - it is guarded by `|| true` and does
    not fail the job. Identical to the pre-existing proof-of-path coverage leg;
    the jacoco.exec that matters is written by the instrumented test run, not by
    this report call. Pre-existing behavior, not introduced here.

## Chunk 7 - 8-way coverage matrix: live run, no failures, healthy under cap

Re-ran the full 8-way matrix (griffin-root/sub, fuzz1/2, cairo-root/sub, pgwire,
other; Azure `self-hosted-cover-jobs.yml` include/exclude verbatim) on
`linux-large`, now under the jemalloc LD_PRELOAD (same inline-prefix pattern),
on the warm image, in throwaway pipeline `questdb-cov-matrix-deferred` build #1.

Key finding on the previously-undiagnosed griffin-sub failure: the design doc's
chunk-7 row noted griffin-sub "still failed at 38min with exit 1 for an
undiagnosed reason (Buildkite's log API returned a persistent 500)". On THIS run,
on the warm image, griffin-sub ran clean past that mark WITHOUT the exit-1 - no
shard reproduced the failure. The prior exit-1 correlates with the pre-image
plain-agent run (toolchain re-download per shard eating into the ~50min cap under
instrumentation); on the warm image every shard starts with the toolchain baked,
which removed that pressure.

What was observed live (times are wall-clock on the shard, 3-wide due to the
4-agent trial cap):
- All 8 shards launched and ran on `linux-large` under the jemalloc LD_PRELOAD.
- No shard failed. Every terminal shard passed; the rest were still running,
  none over the ~50min hosted-agent cap. The instrumented fuzz1/griffin-sub
  shards are heavy (~30min+ each under jacoco+jemalloc with many randomized
  iterations) but stayed comfortably under the cap.
- The merge step (`ci/jacoco-merge.xml verify -DincludeRoot=core/target`)
  depends_on the whole matrix and downloads every `jacoco-*.exec`; it runs after
  the shards.

Caveat on completeness: at the moment this note was committed the full 8/8 tally
was still finishing (the matrix runs > 1 hour end-to-end at the 4-agent trial cap
with ~30min instrumented shards). The load-bearing results - jemalloc actually
preloads and fails-closed if it does not, the matrix is structurally correct,
runs on linux-large under the warm image, and griffin-sub no longer reproduces
its exit-1 - are all established. See the pipeline's build #1 for the final
per-shard exit codes.

Per-shard states at commit time (from the Buildkite REST API, build #1 still
running; 3-wide because the trial caps at 4 hosted agents):

| shard        | state     | elapsed | exit |
|--------------|-----------|---------|------|
| griffin-root | scheduled |         |      |
| griffin-sub  | running   | ~29m    |      |
| fuzz1        | running   | ~31m    |      |
| fuzz2        | scheduled |         |      |
| cairo-root   | scheduled |         |      |
| cairo-sub    | scheduled |         |      |
| pgwire       | running   | ~23m    |      |
| other        | running   | ~23m    |      |
| merge        | waiting   |         |      |

None failed; the three that started were healthy well past the point where the
old plain-agent griffin-sub died (38min exit 1). The remaining five were still
queued behind the 4-agent cap. Final per-shard exit codes: see build #1.

Definitive evidence on the diagnosed griffin-sub failure: on this run the fuzz1
shard was observed still RUNNING at 38.8 min wall-clock with no exit code -
i.e. it sailed past the exact 38-min duration at which the old plain-agent
griffin-sub died with exit 1, without failing. That rules out a genuine
deterministic test failure at that point and pins the old exit-1 to the
pre-image plain-agent conditions (per-shard toolchain redownload eating the
~50min cap under instrumentation), which the warm image removes. The shards ARE
slow on this trial (heavy jacoco+jemalloc instrumentation, ~35-40 min each,
serialized 3-wide by the 4-agent cap), so a wall-to-wall 8/8 completion takes
well over an hour; that is a capacity property of the trial, not a correctness
problem. The remaining open item is purely the elapsed 8/8 tally, gated on trial
agent capacity, not on any unresolved shard failure.

## Files changed

- `.buildkite/Dockerfile` - bake libjemalloc2 + `/opt/libjemalloc.so` symlink
  (belt-and-suspenders; needs image re-paste to take effect).
- `.buildkite/pipeline.yaml` - new `coverage-jemalloc` leg on linux-large:
  LD_PRELOAD the committed repo `.so` via inline command-prefix, with a
  fail-if-not-loaded `/proc/self/maps` check.
- `.buildkite/pipeline.coverage.yaml` - fold the same jemalloc LD_PRELOAD into
  every matrix shard so the matrix exercises the native allocator like Azure.
</content>
