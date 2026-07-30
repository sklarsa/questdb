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
      echo "Rust not baked in; installing via rustup (with rustfmt + clippy)"
      # rustup-init needs a separate --component flag per component (unlike
      # `rustup component add`, which takes a space-separated list).
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component rustfmt --component clippy
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  # rustfmt+clippy are required by the lint leg; add them if a baked/cached
  # toolchain happens to lack them (no-op when already present).
  rustup component add rustfmt clippy >/dev/null 2>&1 || true
}

install_client() {
  # `-P local-client` makes the core build depend on the questdb-client
  # -SNAPSHOT, which lives only in the client submodule and is not published.
  # Build+install it into the local .m2 (matches CLAUDE.md). This is repo state,
  # not toolchain, so it runs every time regardless of the agent image.
  # --recursive: the client carries a nested submodule (zstd).
  git submodule update --init --recursive java-questdb-client
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
