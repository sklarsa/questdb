#!/usr/bin/env bash
# arm64 (aarch64) Linux counterpart of prelude.sh, for the linux-arm-* hosted
# queues. Same contract as prelude.sh - selects/installs JDK 25 + Maven +
# (opt-in) Rust, builds and installs the java-questdb-client -SNAPSHOT with its
# native libquestdb.so, and exports MVN_COMMON - but it produces the
# linux-aarch64 native lib rather than linux-x86-64, and it does NOT need nasm.
#
# Why a separate file (mirrors macos-prelude.sh rather than parameterizing
# prelude.sh): the x86 legs are green and load-bearing, so an arch switch inside
# the shared prelude would risk them. This file is the arm twin; keep the two in
# sync when the shared logic changes.
#
# Two arm-specific differences from prelude.sh:
#  1. No nasm. The client CMake gates the Agner Fog asmlib on ARCH_AMD64
#     (java-questdb-client/core/CMakeLists.txt) - the ARCH_AARCH64 path skips it
#     entirely, exactly like macOS arm64. So ensure_native_build_tools installs
#     only cmake + build-essential.
#  2. linux-aarch64 resource path. The client native lib is staged at
#     .../bin/linux-aarch64/libquestdb.so (the loader's arch dir on arm64),
#     not linux-x86-64.
#
# There is no custom arm64 agent image pinned to these queues (the linux-x86-test
# image is amd64-only), so arm builds run on the PLAIN hosted agent. The fallback
# installers below therefore always fire; they resolve arch from the download URL
# (Temurin linux/aarch64, rustup auto-detect), so no code change is needed for
# the toolchain itself - only the native-artifact paths above differ.
set -euo pipefail

# Pinned versions used by the fallback installers (plain agent has no baked JDK).
JDK_MAJOR=25
MAVEN_VERSION=3.9.9
TOOLS_DIR="${TOOLS_DIR:-$HOME/.buildkite-tools}"
mkdir -p "$TOOLS_DIR"

# Force a UTF-8 locale before any JVM starts (see prelude.sh for the full
# rationale: sun.jnu.encoding drives non-ASCII filename decoding, and a plain
# hosted agent leaves LANG unset).
case "${LC_ALL:-${LANG:-}}" in
  *UTF-8|*UTF8|*utf-8|*utf8) : ;;
  *) export LANG=C.UTF-8; export LC_ALL=C.UTF-8 ;;
esac

ensure_jdk() {
  # Prefer a baked-in JDK 25 (unlikely on the plain arm agent, but cheap to check).
  if [ -n "${JAVA_HOME:-}" ] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -q "version \"25"; then
    return
  fi
  if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q "version \"25"; then
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    return
  fi
  # Fallback: download Temurin for linux/aarch64 (the only arch difference vs the
  # x86 prelude is the /aarch64/ path segment).
  local existing
  existing=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "jdk-${JDK_MAJOR}*" | head -1)
  if [ -z "$existing" ]; then
    echo "JDK 25 not baked in; downloading Temurin (linux/aarch64)"
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/aarch64/jdk/hotspot/normal/eclipse" -o "$TOOLS_DIR/jdk.tar.gz"
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
  # rustup auto-detects aarch64, so this is byte-identical to the x86 prelude.
  if ! command -v cargo >/dev/null 2>&1; then
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
      echo "Rust not baked in; installing via rustup, then adding components"
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
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
  if [ -n "$pinned_chan" ]; then
    echo "Setting rustup default to pinned toolchain: $pinned_chan"
    rustup default "$pinned_chan" >/dev/null 2>&1 || true
  fi
}

ensure_native_build_tools() {
  # cmake compiles the client's native libquestdb.so. NO nasm on arm64: the
  # client CMake gates the asmlib on ARCH_AMD64, so the ARCH_AARCH64 path never
  # assembles an .asm file. Install only cmake + build-essential.
  if command -v cmake >/dev/null 2>&1; then return; fi
  echo "Installing native build tools (cmake) for the arm64 client compile"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y --no-install-recommends cmake build-essential
  else
    echo "WARN: no apt-get; assuming cmake is present"
  fi
}

install_client() {
  # Same rationale as the x86 prelude: the core build depends on the unpublished
  # -SNAPSHOT client, so build+install it from the submodule and stage the native
  # lib onto the production resource path before `mvn clean` wipes target/.
  # The only arm difference is the arch dir: linux-aarch64, not linux-x86-64.
  git submodule update --init --recursive java-questdb-client
  ensure_native_build_tools
  (
    cd java-questdb-client/core
    cmake -DCMAKE_BUILD_TYPE=Release -B cmake-build-release -S.
    cmake --build cmake-build-release --config Release --parallel
    mkdir -p src/main/resources/io/questdb/client/bin/linux-aarch64
    cp target/classes/io/questdb/client/bin-local/libquestdb.so \
       src/main/resources/io/questdb/client/bin/linux-aarch64/libquestdb.so
  ) || { echo "Failed to build client native library"; exit 1; }
  ( cd java-questdb-client && mvn -q clean install -DskipTests ) || {
    echo "Failed to build/install java-questdb-client"; exit 1;
  }
}

ensure_jdk
ensure_maven

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
echo "Locale: LANG=$LANG LC_ALL=$LC_ALL"
echo "Arch: $(uname -m)"
java -XshowSettings:properties -version 2>&1 | grep -iE "sun.jnu.encoding|file.encoding" || true
java -version
mvn -version

# Rust setup is OPT-IN (only the lint leg needs it); set PRELUDE_NEED_RUST=1.
if [ "${PRELUDE_NEED_RUST:-0}" = "1" ]; then
  ensure_rust
  cargo --version || true
fi

# Client build is OPT-IN (test + coverage legs load client classes); set
# PRELUDE_NEED_CLIENT=1.
if [ "${PRELUDE_NEED_CLIENT:-0}" = "1" ]; then
  install_client
fi

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
