#!/usr/bin/env bash
# Coverage-report merge for the Buildkite port.
#
# Mirrors the merge half of Azure's CoverageReports stage
# (ci/test-pipeline.yml): merge the partial JaCoCo .exec files into one
# jacoco.xml, and concatenate + normalize + convert the per-crate Rust LCOV
# files into one cobertura.xml. Both merged reports are uploaded as artifacts.
#
# Deliberately STOPS before Azure's final "Post combined report to GitHub"
# step: that runs cover-checker with a --github-token and --pr to post a
# diff-coverage comment on the PR, which is a PR-facing side effect the eval
# does not publish. This leg produces the merged reports only.
#
# Runs as a sourced/execed script, not an inline command block, to avoid the
# Buildkite command-wrapper's trace-time $VAR pre-expansion (empties cross-line
# vars). prelude.sh must be sourced first (JDK+Maven+client for the JaCoCo
# report's compiled classes).
set -uo pipefail

SRC_DIR="$(pwd)"
DL_DIR="$SRC_DIR/coverage-artifacts"
rm -rf "$DL_DIR"
mkdir -p "$DL_DIR"

# ---- gather upstream coverage artifacts -------------------------------------
# The JaCoCo legs upload the raw jacoco.exec; rust-coverage uploads *.lcov.
# depends_on guarantees those legs finished, but a leg that was skipped (e.g.
# change-detection) may have uploaded nothing, so every download is best-effort.
echo "--- download JaCoCo .exec artifacts"
buildkite-agent artifact download "**/jacoco.exec" "$DL_DIR" || echo "no jacoco.exec artifacts"
echo "--- download Rust LCOV artifacts"
buildkite-agent artifact download "**/*.lcov" "$DL_DIR" || echo "no lcov artifacts"

echo "--- downloaded tree"
find "$DL_DIR" -type f \( -name '*.exec' -o -name '*.lcov' \) | sort

# ---- JaCoCo merge -----------------------------------------------------------
# jacoco-merge.xml globs **/*.exec under includeRoot, merges to aggregate.exec,
# then renders jacoco.xml against core/target/classes (pre-compiled sources).
# So core must be compiled first, exactly as Azure does before this merge.
JACOCO_XML=""
if find "$DL_DIR" -name '*.exec' -type f | grep -q .; then
  echo "--- compile core (jacoco report renders against pre-compiled classes)"
  mvn $MVN_COMMON -pl core -am -DskipTests compile
  echo "--- merge partial JaCoCo reports"
  mvn $MVN_COMMON -f ci/jacoco-merge.xml verify \
    -DincludeRoot="$DL_DIR" \
    -DoutputDirectory="$SRC_DIR/jacoco-aggregate"
  # jacoco-merge.xml writes the report into core/target/classes (its
  # outputDirectory), and the .xml alongside; surface the jacoco.xml path.
  JACOCO_XML="$(find "$SRC_DIR/core/target/classes" core/target -name 'jacoco.xml' -print -quit 2>/dev/null || true)"
  echo "jacoco.xml: ${JACOCO_XML:-<not found>}"
else
  echo "No JaCoCo .exec files present; skipping JaCoCo merge."
fi

# ---- Rust LCOV -> Cobertura -------------------------------------------------
# Concat all per-crate LCOV, normalize CI path prefixes, convert to Cobertura.
# Both merge scripts are Python stdlib-only.
COBERTURA_XML=""
if find "$DL_DIR" -name '*.lcov' -type f | grep -q .; then
  echo "--- merge partial Rust reports"
  find "$DL_DIR" -name '*.lcov' -type f -exec cat {} + > "$SRC_DIR/questdbr-combined.lcov.dat"
  python3 ./ci/merge_lcov_paths.py \
    "$SRC_DIR/questdbr-combined.lcov.dat" "$SRC_DIR/questdbr-patched.lcov.dat"
  python3 ./ci/lcov_cobertura.py \
    "$SRC_DIR/questdbr-patched.lcov.dat" --output "$SRC_DIR/cobertura.xml" --base-dir core/rust
  COBERTURA_XML="$SRC_DIR/cobertura.xml"
  echo "cobertura.xml line-rate: $(grep -o 'line-rate=\"[0-9.]*\"' "$COBERTURA_XML" | head -1)"
else
  echo "No Rust .lcov files present; skipping Cobertura conversion."
fi

# ---- stage merged reports for upload ----------------------------------------
mkdir -p "$SRC_DIR/coverage-merged"
[ -n "$JACOCO_XML" ] && [ -f "$JACOCO_XML" ] && cp "$JACOCO_XML" "$SRC_DIR/coverage-merged/jacoco.xml"
[ -n "$COBERTURA_XML" ] && [ -f "$COBERTURA_XML" ] && cp "$COBERTURA_XML" "$SRC_DIR/coverage-merged/cobertura.xml"

echo "--- merged coverage reports"
ls -la "$SRC_DIR/coverage-merged" || true
# Fail only if we had inputs but produced no output (a real merge failure);
# an all-skipped run (no coverage inputs) is not an error here.
if find "$DL_DIR" -type f \( -name '*.exec' -o -name '*.lcov' \) | grep -q . \
   && ! find "$SRC_DIR/coverage-merged" -type f | grep -q .; then
  echo "FATAL: had coverage inputs but produced no merged report"
  exit 1
fi
