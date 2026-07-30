#!/usr/bin/env bash
# Shared setup for every Buildkite step. Idempotent; safe to run per-step.
#
# Buildkite HOSTED agents are minimal images: no preinstalled Maven, no Rust,
# and no JDK 25 in the default apt repos. So this prelude provisions the whole
# toolchain itself (JDK 25 + Maven + Rust), pins versions, and puts them on
# PATH. Everything resolves from upstream (Temurin / Apache / rustup) - no
# Reposilite cache, no apt mirror. Each tool install is guarded so re-running
# the prelude in a warm agent is cheap.
set -euo pipefail

# Pinned tool versions. Bump here in one place.
JDK_MAJOR=25
MAVEN_VERSION=3.9.9
# Where we drop downloaded toolchains. TOOLS_DIR persists per-agent-boot; the
# guards below skip re-download when it is already populated.
TOOLS_DIR="${TOOLS_DIR:-$HOME/.buildkite-tools}"
mkdir -p "$TOOLS_DIR"

os=$(uname -s)
arch=$(uname -m)

install_jdk() {
  # Temurin has JDK 25 for both linux and macos, x64 and arm64. The default
  # Ubuntu apt repos do NOT carry openjdk-25, so download the tarball instead.
  local existing
  existing=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "jdk-${JDK_MAJOR}*" | head -1)
  if [ -n "$existing" ]; then
    export JAVA_HOME="$existing"
    return
  fi

  local tos tarch
  case "$os" in
    Linux)  tos=linux ;;
    Darwin) tos=mac ;;
    *) echo "Unsupported OS for JDK install: $os"; exit 1 ;;
  esac
  case "$arch" in
    x86_64)         tarch=x64 ;;
    aarch64|arm64)  tarch=aarch64 ;;
    *) echo "Unsupported arch for JDK install: $arch"; exit 1 ;;
  esac

  # Adoptium redirect API always resolves the latest GA build for the major.
  local url="https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/${tos}/${tarch}/jdk/hotspot/normal/eclipse"
  echo "Downloading Temurin JDK ${JDK_MAJOR} (${tos}/${tarch})"
  curl -fsSL "$url" -o "$TOOLS_DIR/jdk.tar.gz"
  tar -xzf "$TOOLS_DIR/jdk.tar.gz" -C "$TOOLS_DIR"
  rm -f "$TOOLS_DIR/jdk.tar.gz"

  local dir
  dir=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name "jdk-${JDK_MAJOR}*" | head -1)
  # macOS tarballs nest the JDK under Contents/Home.
  if [ "$os" = "Darwin" ] && [ -d "$dir/Contents/Home" ]; then
    dir="$dir/Contents/Home"
  fi
  export JAVA_HOME="$dir"
}

install_maven() {
  local mvn_home="$TOOLS_DIR/apache-maven-${MAVEN_VERSION}"
  if [ ! -x "$mvn_home/bin/mvn" ]; then
    echo "Downloading Apache Maven ${MAVEN_VERSION}"
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o "$TOOLS_DIR/maven.tar.gz"
    tar -xzf "$TOOLS_DIR/maven.tar.gz" -C "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/maven.tar.gz"
  fi
  export PATH="$mvn_home/bin:$PATH"
}

install_rust() {
  # Only the lint leg needs Rust, but installing it everywhere is cheap when
  # rustup is cached and keeps the prelude uniform. rust-toolchain.toml in
  # core/rust/qdbr pins the exact toolchain; rustup honors it on first cargo use.
  # The lint leg runs `cargo fmt` and `cargo clippy`, so rustfmt+clippy must be
  # present - the "minimal" profile omits both, so request them explicitly.
  if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    echo "Installing Rust via rustup (with rustfmt + clippy)"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component rustfmt clippy
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  # Ensure the components exist even if a cached rustup lacks them.
  rustup component add rustfmt clippy >/dev/null 2>&1 || true
}

install_client() {
  # `-P local-client` makes the core build depend on org.questdb:questdb-client
  # at the -SNAPSHOT version, which lives only in the client submodule. Nobody
  # publishes it, so build+install it into the local .m2 here (matches
  # CLAUDE.md's "cd java-questdb-client && mvn clean install -DskipTests").
  # --recursive: the client carries its own nested submodule (zstd).
  git submodule update --init --recursive java-questdb-client
  ( cd java-questdb-client && mvn -q clean install -DskipTests ) || {
    echo "Failed to build/install java-questdb-client"; exit 1;
  }
}

install_jdk
install_maven
install_rust

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
java -version
mvn -version
cargo --version || true

# Build+install the client SNAPSHOT into .m2 (needs Maven+JDK on PATH above).
install_client

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
