#!/usr/bin/env bash
# macOS (ARM64) counterpart of prelude.sh, for the macos-large hosted queue.
# Same contract as prelude.sh - selects/installs JDK 25 + Maven, builds and
# installs the java-questdb-client -SNAPSHOT with its native libquestdb.dylib,
# and exports MVN_COMMON - but sourced from Homebrew instead of apt, and it
# produces the darwin-aarch64 native lib rather than linux-x86-64.
#
# The client's CMake already handles arm64 macOS: it takes the ARCH_AARCH64
# path (vanilla arithmetic, no Agner Fog asmlib) and the OS_DARWIN path, so
# nasm is NOT needed here (unlike the x86 Linux build). See
# java-questdb-client/core/CMakeLists.txt.
set -euo pipefail

MACOS_JDK_MAJOR=25

ensure_jdk() {
  # Prefer a JDK 25 already on the image (JAVA_HOME set, or java on PATH, or a
  # /Library/Java/JavaVirtualMachines install). Fall back to `brew install
  # openjdk@25`, which is a keg-only formula - symlink its bin so `java` and
  # JAVA_HOME resolve.
  if [ -n "${JAVA_HOME:-}" ] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -q "version \"${MACOS_JDK_MAJOR}"; then
    return
  fi
  if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q "version \"${MACOS_JDK_MAJOR}"; then
    export JAVA_HOME="$(/usr/libexec/java_home -v ${MACOS_JDK_MAJOR} 2>/dev/null || dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    return
  fi
  local libexec_home
  libexec_home="$(/usr/libexec/java_home -v ${MACOS_JDK_MAJOR} 2>/dev/null || true)"
  if [ -n "$libexec_home" ]; then export JAVA_HOME="$libexec_home"; return; fi
  echo "JDK ${MACOS_JDK_MAJOR} not present; installing via Homebrew"
  brew install "openjdk@${MACOS_JDK_MAJOR}"
  # brew openjdk is keg-only; its real home is under the Cellar / opt prefix.
  local brew_prefix
  brew_prefix="$(brew --prefix "openjdk@${MACOS_JDK_MAJOR}")"
  export JAVA_HOME="$brew_prefix/libexec/openjdk.jdk/Contents/Home"
}

ensure_maven() {
  if command -v mvn >/dev/null 2>&1; then return; fi
  echo "Maven not present; installing via Homebrew"
  brew install maven
}

ensure_native_build_tools() {
  # cmake compiles the client's native libquestdb.dylib. No nasm on arm64 macOS -
  # the client CMake's ARCH_AARCH64 path skips the asmlib entirely.
  if command -v cmake >/dev/null 2>&1; then return; fi
  echo "cmake not present; installing via Homebrew"
  brew install cmake
}

install_client() {
  # Same rationale as the Linux prelude: the core build depends on the
  # -SNAPSHOT client, which is not published, so build+install it from the
  # submodule. The submodule no longer commits native libs, so compile
  # libquestdb.dylib for darwin-aarch64 and stage it onto the production
  # resource path before `mvn clean` wipes target/.
  git submodule update --init --recursive java-questdb-client
  ensure_native_build_tools
  (
    cd java-questdb-client/core
    cmake -DCMAKE_BUILD_TYPE=Release -B cmake-build-release -S.
    cmake --build cmake-build-release --config Release --parallel
    mkdir -p src/main/resources/io/questdb/client/bin/darwin-aarch64
    cp target/classes/io/questdb/client/bin-local/libquestdb.dylib \
       src/main/resources/io/questdb/client/bin/darwin-aarch64/libquestdb.dylib
  ) || { echo "Failed to build client native library"; exit 1; }
  ( cd java-questdb-client && mvn -q clean install -DskipTests ) || {
    echo "Failed to build/install java-questdb-client"; exit 1;
  }
}

ensure_jdk
ensure_maven

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
java -version
mvn -version

install_client

# Same shared Maven flags as the Linux prelude: central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
