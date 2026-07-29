#!/usr/bin/env bash
# Shared setup for every Buildkite step. Idempotent; safe to run per-step.
# Clean-room hosted agents: no Reposilite cache, no apt mirror. Maven resolves
# from Central. Installs JDK 25 on Linux; macOS agents ship a JDK we select.
set -euo pipefail

install_jdk_linux() {
  if [ -d /usr/lib/jvm/java-25-openjdk-amd64 ]; then
    export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
    return
  fi
  sudo apt-get update
  sudo apt-get install -y openjdk-25-jdk
  export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
}

select_jdk_macos() {
  # Buildkite macOS images ship multiple JDKs; pick 25.
  JH=$(/usr/libexec/java_home -v 25 2>/dev/null || true)
  if [ -z "$JH" ]; then
    echo "JDK 25 not found on macOS agent; installing via brew"
    brew install openjdk@25
    JH=$(/usr/libexec/java_home -v 25)
  fi
  export JAVA_HOME="$JH"
}

case "$(uname -s)" in
  Linux)  install_jdk_linux ;;
  Darwin) select_jdk_macos ;;
  *) echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

export PATH="$JAVA_HOME/bin:$PATH"
echo "Using JAVA_HOME=$JAVA_HOME"
java -version

git submodule update --init java-questdb-client

# Common Maven flags shared by every leg. Central-only, batch, local-client.
export MVN_COMMON="--batch-mode -P local-client -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
echo "MVN_COMMON=$MVN_COMMON"
