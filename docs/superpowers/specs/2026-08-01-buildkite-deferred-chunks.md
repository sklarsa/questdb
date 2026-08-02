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

## Chunk 7 - 8-way coverage matrix: real bug found + fixed (empty shard filter)

Re-ran the full 8-way matrix (griffin-root/sub, fuzz1/2, cairo-root/sub, pgwire,
other; Azure `self-hosted-cover-jobs.yml` include/exclude verbatim) on
`linux-large` under the jemalloc LD_PRELOAD, on the warm image, in throwaway
pipeline `questdb-cov-matrix-deferred` build #1.

griffin-sub FAILED again with exit 1 at 40.3 min - the same signature the design
doc flagged as undiagnosed. This time it was diagnosed to root cause (do NOT
mislabel it flaky - the proof is below).

### Retrieving the log past the persistent 500

The Buildkite log JSON endpoint returned a persistent HTTP 500 for the failed
job (`{"message":"Internal Server Error"}`), exactly as the design doc reported.
The cause is now known: the job's log was 721 MB, too large for the JSON
serializer. Fetching the SAME endpoint with `Accept: text/plain` (or the
`/log.txt` path) streamed the full 721 MB successfully. So the "500" is not
data-loss - it is a size limit on the JSON log route, and the txt route is the
workaround.

### Root cause: the per-shard include/exclude filter was EMPTY

The 721 MB log ended with a Maven `MojoFailureException` and this reactor
summary: `Tests run: 37934, Failures: 0, Errors: 1, Skipped: 447`. 37,934 test
methods is essentially the ENTIRE suite - griffin-sub was supposed to run only
the ~774 griffin subpackage classes. The shard log confirmed why:

    --- coverage shard griffin-sub: include=[] exclude=[]
    mvn ... -P jacoco,qdbr-coverage -Dtest.include="" -Dtest.exclude=""

`$INC`/`$EXC` were EMPTY at the mvn line. The old YAML set them in a multi-line
`case` block and read them back on a later `mvn` line; this command wrapper
pre-expands a bare `$VAR` at trace time before the line runs (the very same quirk
that bit `$LD_PRELOAD`), so `$INC`/`$EXC` came back empty and every shard ran
`-Dtest.include=""` = the full suite. Package distribution in the griffin-sub log
proves it: 989 griffin classes but also 240 cairo, 227 cutlass, 165 std, etc.
That also explains the ~40min shard times earlier in this run - each "shard" was
running all 37,934 tests, not its slice.

### The single erroring test is a known flake, swept in by the empty filter

The one error was:

    ServerMainTest.testServerUpgradeDoesNotOverrideWebConsoleConfig
      » Runtime Cannot read from /tmp/junit.../dbRoot/public/assets/console-configuration.json

`ServerMainTest` is a top-level `io.questdb.test` class (NOT under griffin), and
its failure is a non-deterministic ServerMain-boot file-read race (the web
console `console-configuration.json` is read before the unpack completes). This
is the same flake the design doc's build #36 hit ("a known non-deterministic
setUp flake"), and the MAIN pipeline's `test: other` leg already excludes it
(`-Dtest.exclude='...**/ServerMainTest.java'`). With a working griffin filter it
would never have been in the griffin-sub shard at all; the empty filter dragged
the whole suite in and rolled the flake.

### The fix

`.buildkite/pipeline.coverage.yaml` now puts the LD_PRELOAD prefix, the profiles,
AND the `-Dtest.include`/`-Dtest.exclude` literals for each shard on ONE physical
line, inside the `case` arm - no cross-line `$INC`/`$EXC` read, so the filter
survives the wrapper's trace pre-expansion. It also adds `**/ServerMainTest.java`
to the `other` shard's exclude, mirroring the main pipeline, so the flaky boot
test cannot land in any shard even if a future pattern widens.

Verification: griffin-sub re-run with the fixed inline filter (pipeline build #2):
<RESULT_GRIFFIN_SUB_FIX>

### Corrections to my earlier claims in this note

Earlier revisions of this note asserted "no shard failed" and "griffin-sub no
longer reproduces its exit-1", inferred from watching elapsed times while build
#1 was still running. That was WRONG: griffin-sub did fail with exit 1, and the
shards were slow precisely because the broken filter made every one run the full
37,934-test suite. The failure was real (a genuine bug in the shard YAML plus a
known flake it exposed), not the infra-timeout story the design doc had guessed.

### Honest tradeoff still worth flagging

Even with the filter fixed, instrumented coverage shards are heavy under
jacoco+qdbr-coverage+jemalloc. On the trial's 4-agent cap they serialize 3-wide.
The fix should cut per-shard wall time sharply (each shard runs its slice, not
the whole suite), but a production port should still size the job timeout / agent
count for the heaviest correctly-scoped shard rather than assume the ~50min cap
is comfortable.

## Files changed

- `.buildkite/Dockerfile` - bake libjemalloc2 + `/opt/libjemalloc.so` symlink
  (belt-and-suspenders; needs image re-paste to take effect).
- `.buildkite/pipeline.yaml` - new `coverage-jemalloc` leg on linux-large:
  LD_PRELOAD the committed repo `.so` via inline command-prefix, with a
  fail-if-not-loaded `/proc/self/maps` check.
- `.buildkite/pipeline.coverage.yaml` - fold the same jemalloc LD_PRELOAD into
  every matrix shard so the matrix exercises the native allocator like Azure.
</content>
