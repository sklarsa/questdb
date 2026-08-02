# Custom Buildkite hosted-agent image for the QuestDB OSS smoke test.
#
# Paste the CONTENTS BELOW the FROM line into the Buildkite custom-agent-image
# editor. Buildkite pins the `FROM buildkite/hosted-agent-base:...` line itself
# and it cannot be changed; do not add your own FROM. The buildkite-agent and
# docker binaries are injected at runtime, so this image must NOT install them.
# Buildkite also forbids changing USER / UID / GID here, so everything installs
# system-wide as-is.
#
# This bakes in the toolchain the pipeline previously provisioned per-run in
# prelude.sh (JDK 25, Maven, Rust+rustfmt+clippy, native-build deps), so builds
# start warm instead of downloading ~300 MB of tools on every leg. Adapted from
# azure-ci-runners roles/incus/files/provision.sh, trimmed to just what the OSS
# smoke test needs (dropped Azure/AWS/Trivy/Packer/gh/GraalVM operator tooling).
FROM buildkite/hosted-agent-base:latest

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling. git + ca-certificates + bash are Buildkite hard requirements;
# build-essential + cmake + zip/unzip cover the native client/zstd compile;
# libicu + locale support the encoding-sensitive tests. JDK 25 is NOT taken
# from apt: openjdk-25-jdk is not reliably in the base image's apt repos (the
# plain hosted agent lacked it), so it is installed from the Temurin tarball
# below, which is distro-independent. Maven comes from apt (its default-jre
# dependency is unused - JAVA_HOME below points every tool at Temurin 25).
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
        git \
        jq \
        unzip \
        zip \
        build-essential \
        cmake \
        libicu-dev \
        libjemalloc2 \
        locales \
        maven \
    && rm -rf /var/lib/apt/lists/*

# jemalloc under coverage instrumentation. The coverage leg LD_PRELOADs the
# libjemalloc.so committed in the repo at core/src/main/bin/linux-x86-64/, which
# is the primary, image-independent path (that file is always in the checkout).
# This apt install is a belt-and-suspenders fallback so a KNOWN symlink also
# exists on the image, avoiding the runtime ldconfig/find discovery that sank the
# earlier attempts. libjemalloc2 installs the versioned .so.2; the dev-less
# symlink below gives the coverage step a stable, discovery-free path to fall
# back to. See docs/superpowers/specs/2026-08-01-buildkite-deferred-chunks.md.
RUN set -eux; \
    jem="$(dpkg -L libjemalloc2 | grep -m1 'libjemalloc\.so\.2$')"; \
    ln -sf "$jem" /opt/libjemalloc.so; \
    test -e /opt/libjemalloc.so

# UTF-8 locale: several QuestDB tests assert on default platform encoding.
RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# JDK 25 from Temurin (distro-independent; the deb repo does not carry it).
# Adoptium's redirect API resolves the latest GA build for the major version.
RUN curl -fsSL "https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse" \
      -o /tmp/jdk.tar.gz \
    && mkdir -p /opt/jdk \
    && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1 \
    && rm /tmp/jdk.tar.gz
ENV JAVA_HOME=/opt/jdk
ENV PATH=$JAVA_HOME/bin:$PATH

# Rust system-wide, with the components the lint leg needs (rustfmt, clippy).
# CARGO_HOME/RUSTUP_HOME are set to a world-readable path so the injected
# runtime user (which we cannot change) can still run cargo.
# Install rustup first, then add components via `rustup component add` (which
# reliably takes a space-separated list) - passing --component to the rustup-init
# installer is version-fragile and failed the image build with "unexpected
# argument 'clippy'".
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:$PATH
# The lint crates (qdb-core, qdbr) pin a nightly via rust-toolchain.toml and
# rustup installs a pinned toolchain WITHOUT components, so rustfmt/clippy must
# be added to that nightly, not just stable. Keep RUST_NIGHTLY in sync with
# core/rust/*/rust-toolchain.toml (channel = "...").
ENV RUST_NIGHTLY=nightly-2025-09-24
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --no-modify-path \
    && /opt/rust/cargo/bin/rustup component add rustfmt clippy \
    && /opt/rust/cargo/bin/rustup toolchain install "$RUST_NIGHTLY" --profile minimal \
    && /opt/rust/cargo/bin/rustup component add --toolchain "$RUST_NIGHTLY" rustfmt clippy \
    && chmod -R a+rwX /opt/rust

# Warm the Maven wrapper/version so the first real build does not pay for it.
RUN mvn -version && java -version && cargo --version && rustfmt --version && cargo clippy --version
