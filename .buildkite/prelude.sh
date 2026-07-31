#!/usr/bin/env bash
# Shared setup for every Buildkite step. Idempotent; safe to run per-step.
# Scope: Linux x86_64 hosted agents only (macOS and arm64 are out of scope for
# now).
#
# Preferred setup: run on the custom hosted-agent image built from
# .buildkite/Dockerfile, which bakes in JDK 25, Maven, and Rust (with
# rustfmt+clippy). On that image the checks below are near-instant no-ops.
#
# Fallback: if a tool is missing (e.g. running on a plain hosted agent), this
# provisions it from upstream (Temurin / Apache / rustup) so the pipeline still
# works off-image. Everything resolves from upstream - no Reposilite, no apt
# mirror.
set -euo pipefail

# Pinned versions used only by the fallback installers.
JDK_MAJOR=25
MAVEN_VERSION=3.9.9
TOOLS_DIR="${TOOLS_DIR:-$HOME/.buildkite-tools}"
mkdir -p "$TOOLS_DIR"

# Force a UTF-8 locale before any JVM starts. The JVM derives sun.jnu.encoding
# (the charset it uses to decode filenames from the OS) from LANG/LC_ALL at
# startup. On a plain hosted agent LANG is unset, so sun.jnu.encoding becomes
# ANSI_X3.4-1968 and Java's File.getName() mojibakes non-ASCII filenames -
# FilesTest.testSoftLinkNonAsciiName then sees a Japanese name come back as 3x
# its length (each UTF-8 byte decoded as one char). The custom image bakes
# LANG=en_US.UTF-8 but builds fall back to the plain agent, so set it here.
# C.UTF-8 needs no locale-gen and is present on modern glibc. Override unless
# an existing locale is already UTF-8 (the image sets en_US.UTF-8; a plain
# agent leaves LANG empty or C/POSIX, both of which must be replaced).
case "${LC_ALL:-${LANG:-}}" in
  *UTF-8|*UTF8|*utf-8|*utf8) : ;;
  *) export LANG=C.UTF-8; export LC_ALL=C.UTF-8 ;;
esac

ensure_jdk() {
  # Prefer a baked-in JDK 25 (JAVA_HOME set by the image, or java on PATH).
  if [ -n "${JAVA_HOME:-}" ] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -q "version \"25"; then
    return
  fi
  if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q "version \"25"; then
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    return
  fi
  # Fallback: download Temurin (the deb repos do not carry openjdk-25).
  local existing
  existing=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "jdk-${JDK_MAJOR}*" | head -1)
  if [ -z "$existing" ]; then
    echo "JDK 25 not baked in; downloading Temurin (linux/x64)"
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" -o "$TOOLS_DIR/jdk.tar.gz"
    tar -xzf "$TOOLS_DIR/jdk.tar.gz" -C "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/jdk.tar.gz"
    existing=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "jdk-${JDK_MAJOR}*" | head -1)
  fi
  export JAVA_HOME="$existing"
}

ensure_maven() {
  if command -v mvn >/dev/null 2>&1; then return; fi
  local mvn_home="$TOOLS_DIR/apache-maven-${MAVEN_VERSION}"
  if [ ! -x "$mvn_home/bin/mvn" ]; then
    echo "Maven not baked in; downloading Apache Maven ${MAVEN_VERSION}"
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o "$TOOLS_DIR/maven.tar.gz"
    tar -xzf "$TOOLS_DIR/maven.tar.gz" -C "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/maven.tar.gz"
  fi
  export PATH="$mvn_home/bin:$PATH"
}

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
      echo "Rust not baked in; installing via rustup, then adding components"
      # Passing --component to the rustup-init installer is version-fragile; add
      # components afterward with `rustup component add` (below), which reliably
      # takes a space-separated list.
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  # rustfmt+clippy are required by the lint leg. The lint crates pin a specific
  # nightly via rust-toolchain.toml, and rustup installs that pinned toolchain
  # WITHOUT components - so adding them to the default (stable) toolchain is not
  # enough; cargo fmt inside the crate uses the nightly and fails with
  # "cargo-fmt is not installed for the toolchain 'nightly-...'". Add the
  # components to every pinned channel found under core/rust, plus the default.
  rustup component add rustfmt clippy >/dev/null 2>&1 || true
  local pinned_chan=""
  for tf in core/rust/qdb-core/rust-toolchain.toml core/rust/qdbr/rust-toolchain.toml core/rust/qdb-parquet-meta/rust-toolchain.toml; do
    [ -f "$tf" ] || continue
    chan=$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$tf" | head -1)
    [ -n "$chan" ] || continue
    echo "Ensuring rustfmt+clippy on pinned toolchain: $chan"
    rustup toolchain install "$chan" >/dev/null 2>&1 || true
    rustup component add --toolchain "$chan" rustfmt clippy >/dev/null 2>&1 || true
    [ -z "$pinned_chan" ] && pinned_chan="$chan"
  done
  # Make the pinned nightly the rustup default, mirroring Azure's
  # prepare_rust_env.py (which installs the nightly as --default-toolchain).
  # Not every lint crate carries a rust-toolchain.toml: qdb-parquet-meta has
  # none, so `cd core/rust/qdb-parquet-meta && cargo clippy` would otherwise run
  # under the agent image's default (a newer stable), whose clippy carries lints
  # the pinned nightly lacks - a spurious divergence from Azure. Pinning the
  # default keeps every crate on one clippy, matching Azure like-for-like.
  if [ -n "$pinned_chan" ]; then
    echo "Setting rustup default to pinned toolchain: $pinned_chan"
    rustup default "$pinned_chan" >/dev/null 2>&1 || true
  fi
}

ensure_native_build_tools() {
  # cmake + nasm compile the client's native libquestdb.so (nasm assembles the
  # x86-64 asmlib). The custom image bakes cmake+build-essential but not nasm;
  # a plain hosted agent may lack all three. Install whatever is missing.
  if command -v cmake >/dev/null 2>&1 && command -v nasm >/dev/null 2>&1; then return; fi
  echo "Installing native build tools (cmake/nasm) for the client compile"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y --no-install-recommends cmake nasm build-essential
  else
    echo "WARN: no apt-get; assuming cmake/nasm are present"
  fi
}

install_client() {
  # `-P local-client` makes the core build depend on the questdb-client
  # -SNAPSHOT, which lives only in the client submodule and is not published.
  # Build+install it into the local .m2 (matches CLAUDE.md). This is repo state,
  # not toolchain, so it runs every time regardless of the agent image.
  # --recursive: the client carries a nested submodule (zstd, needed by CMake).
  git submodule update --init --recursive java-questdb-client
  # The client submodule no longer commits its compiled native libraries, so a
  # -SNAPSHOT client jar built from source ships without libquestdb.so. Every
  # client-dependent test then dies at class load with
  #   FatalError: cannot find /io/questdb/client/bin/linux-x86-64/libquestdb.so
  # Compile it here (mirrors ci/templates/build-client-native.yml, Linux path).
  # CMake writes to core/target/classes/.../bin-local/, which the mvn clean
  # below would wipe; copy it into the client's source resources so it survives
  # the clean and lands on the production resource path the loader checks first
  # (see io.questdb.client.std.Os). Linux x86-64 only - the sole Buildkite target.
  ensure_native_build_tools
  (
    cd java-questdb-client/core
    cmake -DCMAKE_BUILD_TYPE=Release -B cmake-build-release -S.
    cmake --build cmake-build-release --config Release --parallel
    mkdir -p src/main/resources/io/questdb/client/bin/linux-x86-64
    cp target/classes/io/questdb/client/bin-local/libquestdb.so \
       src/main/resources/io/questdb/client/bin/linux-x86-64/libquestdb.so
  ) || { echo "Failed to build client native library"; exit 1; }
  ( cd java-questdb-client && mvn -q clean install -DskipTests ) || {
    echo "Failed to build/install java-questdb-client"; exit 1;
  }
}

locate_jemalloc() {
  # Echo the path to libjemalloc on stdout, installing it if missing. Used only
  # by the jemalloc coverage leg to LD_PRELOAD the native allocator under
  # instrumentation (mirrors Azure self-hosted-cover-jobs.yml). All chatter goes
  # to stderr so the caller captures a clean path from stdout.
  #
  # The whole body runs under `set +e` in a subshell. Builds #26/#27/#28 all
  # failed here NOT because libjemalloc was absent - apt installed it every time
  # ("Setting up libjemalloc2") - but because this resolver ran inside a command
  # substitution under the prelude's `set -euo pipefail`. A benign non-zero exit
  # (an empty `grep`, a `head` closing a pipe early -> SIGPIPE on `find`) aborted
  # the function mid-way, so the post-install lookup never ran and the diagnostic
  # branch never printed. Dropping `set -e` for this body removes that whole
  # class of abort; the resolution logic itself was always correct.
  (
    set +e
    _resolve() {
      local q
      q=$(ldconfig -p 2>/dev/null | grep -m1 'libjemalloc\.so' | awk '{print $NF}')
      if [ -n "$q" ] && [ -e "$q" ]; then printf '%s' "$q"; return; fi
      # The libjemalloc2 package installs to /usr/lib/<arch-triplet>/; search the
      # common lib roots wholesale rather than assume the triplet.
      find /usr/lib /lib /usr/local/lib -name 'libjemalloc.so*' 2>/dev/null | sort | head -1
    }
    p=$(_resolve)
    if [ -z "$p" ] && command -v apt-get >/dev/null 2>&1; then
      echo "jemalloc not present; installing libjemalloc2" >&2
      sudo apt-get update >&2
      sudo apt-get install -y --no-install-recommends libjemalloc2 >&2
      sudo ldconfig >&2 2>&1
      p=$(_resolve)
    fi
    if [ -z "$p" ]; then
      echo "locate_jemalloc: empty after install; diagnostics follow" >&2
      echo "  dpkg -L libjemalloc2:" >&2; dpkg -L libjemalloc2 2>&1 | grep -i jemalloc >&2
      echo "  find / -name libjemalloc*:" >&2; find / -name 'libjemalloc*' 2>/dev/null >&2
      echo "  ldconfig -p | grep jemalloc:" >&2; ldconfig -p 2>/dev/null | grep -i jemalloc >&2
    fi
    printf '%s' "$p"
  )
}

ensure_jdk
ensure_maven
ensure_rust

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
echo "Locale: LANG=$LANG LC_ALL=$LC_ALL"
# Confirm the JVM actually derives a UTF-8 sun.jnu.encoding from the locale;
# this is the property that governs File.getName() decoding of non-ASCII names.
java -XshowSettings:properties -version 2>&1 | grep -iE "sun.jnu.encoding|file.encoding" || true
java -version
mvn -version
cargo --version || true

install_client

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
