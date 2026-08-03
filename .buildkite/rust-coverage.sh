#!/usr/bin/env bash
# Rust cargo-test coverage collection for the Buildkite port.
#
# Mirrors Azure ci/templates/rust-test-and-lint.yml (the "Rust coverage
# collection" half) plus ci/templates/install-llvm.yml. Runs the four Rust test
# suites under LLVM source-based coverage instrumentation, then merges the
# profraw output into one LCOV file per crate for the coverage-report merge.
#
# Why a sourced .sh and not an inline `command:` block: Buildkite's command
# wrapper pre-expands a bare $VAR at trace time, before the line runs, so a var
# set on one line reads back EMPTY on a later line (the quirk that sank the
# jemalloc and coverage-matrix legs). Inside a real script sourced/executed as
# one file, ordinary shell semantics apply and cross-line vars work, so the
# Azure logic ports almost verbatim. prelude.sh must be sourced first (Rust
# toolchain on PATH via PRELUDE_NEED_RUST=1).
set -euo pipefail

SRC_DIR="$(pwd)"
PROFRAW_DIR="$SRC_DIR/rust-lint-profraw"

echo "--- clean previous profraw"
find . -name '*.profraw' -delete || true
rm -rf "$PROFRAW_DIR"
mkdir -p "$PROFRAW_DIR"

# One instrumented `cargo test` per crate. Each writes profraw into PROFRAW_DIR
# under a crate-specific %m pattern so the per-crate merge below can glob them
# apart. -D warnings matches Azure (a warning fails the instrumented build too).
run_crate_tests() {
  local crate="$1" dir="$2"
  echo "--- $crate: cargo test (coverage)"
  (
    cd "$dir"
    RUSTFLAGS="-C instrument-coverage -D warnings" \
    LLVM_PROFILE_FILE="$PROFRAW_DIR/${crate}-%m.profraw" \
      cargo test --all-targets --no-fail-fast
  )
}

run_crate_tests qdb-core         core/rust/qdb-core
run_crate_tests qdb-parquet-meta core/rust/qdb-parquet-meta
run_crate_tests qdbr             core/rust/qdbr

# parquet2 needs the apache/parquet-testing fixtures submodule and skips the
# pyarrow-dependent tests, exactly as Azure does.
echo "--- parquet2: init parquet-testing submodule"
git submodule update --init core/rust/parquet2/testing/parquet-testing
echo "--- parquet2: cargo test (coverage)"
(
  cd core/rust/parquet2
  PARQUET2_IGNORE_PYARROW_TESTS=1 \
  RUSTFLAGS="-C instrument-coverage -D warnings" \
  LLVM_PROFILE_FILE="$PROFRAW_DIR/parquet2-%m.profraw" \
    cargo test --all-targets --no-fail-fast
)

# LLVM coverage tools (llvm-profdata / llvm-cov) ship with the pinned toolchain's
# llvm-tools-preview component. Add it to whatever toolchain rustup resolves here
# (prelude pins the nightly default), then locate the binaries.
echo "--- install llvm-tools-preview + locate tools"
rustup component add llvm-tools-preview
LLVM_TOOLS_PATH="$(dirname "$(rustup which llvm-profdata 2>/dev/null \
  || find "$HOME/.rustup/toolchains" -name llvm-profdata -print -quit)")"
export PATH="$LLVM_TOOLS_PATH:$PATH"
llvm-profdata --version | head -1
llvm-cov --version | head -1

# Strip registry deps and the rust stdlib from the report, matching Azure.
IGNORE_RE='(.cargo/registry|rustc/.*\.rs)'

# Merge one crate's profraw -> profdata -> LCOV against its own test binaries.
generate_lcov() {
  local crate="$1" target_dir="$2"
  local -a profraw
  mapfile -t profraw < <(find "$PROFRAW_DIR" -name "${crate}-*.profraw" | sort)
  if [ "${#profraw[@]}" -eq 0 ]; then
    echo "No $crate profraw files found, skipping"
    return
  fi
  llvm-profdata merge -sparse -o "$PROFRAW_DIR/$crate.profdata" "${profraw[@]}"

  local -a bins
  mapfile -d '' -t bins < <(find "$target_dir/deps" -maxdepth 1 -type f -executable \
    ! -name '*.so' ! -name '*.dylib' ! -name '*.dll' ! -name '*.d' -print0 | sort -z)
  local -a object_args=()
  local bin
  for bin in "${bins[@]}"; do
    object_args+=(--object "$bin")
  done

  llvm-cov export \
    --format=lcov \
    --ignore-filename-regex="$IGNORE_RE" \
    "${object_args[@]}" \
    --instr-profile="$PROFRAW_DIR/$crate.profdata" \
    > "$PROFRAW_DIR/$crate.lcov"
  echo "Generated $crate.lcov ($(grep -c '^SF:' "$PROFRAW_DIR/$crate.lcov") source files)"
}

echo "--- create LCOV reports"
generate_lcov qdb-core         core/rust/qdb-core/target/debug
generate_lcov qdb-parquet-meta core/rust/qdb-parquet-meta/target/debug
generate_lcov qdbr             core/rust/qdbr/target/debug
generate_lcov parquet2         core/rust/parquet2/target/debug

# Keep profdata + lcov for the coverage-report merge; drop the bulky profraw.
rm -f "$PROFRAW_DIR"/*.profraw

echo "--- LCOV artifacts ready"
ls -la "$PROFRAW_DIR"
