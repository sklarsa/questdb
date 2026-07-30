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

ensure_jdk
ensure_maven
ensure_rust

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
java -version
mvn -version
cargo --version || true

install_client

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
