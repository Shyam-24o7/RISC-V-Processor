# Pinned toolchain. Versions are fixed so Phase 5 results stay comparable with
# Phase 1 results measured months earlier.
# Base image is digest-pinned (not just tag-pinned): "ubuntu:24.04" is a moving
# tag that gets repointed at new point releases, which would silently change
# the apt-served packages below (gcc-riscv64-unknown-elf in particular).
FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

ARG VERILATOR_TAG=v5.026
ARG SPIKE_TAG=v1.1.0
ARG OSS_CAD=2024-09-01

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates wget xz-utils python3 python3-pip \
      autoconf automake libtool flex bison help2man perl \
      libfl-dev zlib1g-dev libgoogle-perftools-dev numactl \
      device-tree-compiler libboost-regex-dev libboost-system-dev \
      gcc-riscv64-unknown-elf \
    && rm -rf /var/lib/apt/lists/*

# oss-cad-suite gives yosys + sby + boolector/yices/z3 in one prebuilt tarball.
# Placed BEFORE the source builds deliberately: this is a large, slow download
# (~24 min observed), and Docker invalidates every layer after a changed one.
# With it last, any edit to the Spike or Verilator recipe re-downloaded it.
RUN wget -q -O /tmp/oss.tgz \
      "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD}/oss-cad-suite-linux-x64-$(echo ${OSS_CAD} | tr -d '-').tgz" \
    && tar -xzf /tmp/oss.tgz -C /opt && rm /tmp/oss.tgz
# Appended, not prepended: oss-cad-suite bundles its own verilator build, and if
# placed ahead of /usr/local/bin it silently shadows the source-built, pinned
# VERILATOR_TAG below. Putting it last means yosys/sby (found nowhere else)
# still resolve, while our pinned verilator wins. This holds regardless of layer
# order, because /usr/local/bin precedes it in the default PATH.
ENV PATH="${PATH}:/opt/oss-cad-suite/bin"

# Verilator - built from source so the version is exact, not whatever apt ships.
RUN git clone --depth 1 --branch ${VERILATOR_TAG} https://github.com/verilator/verilator /tmp/verilator \
    && cd /tmp/verilator && autoconf && ./configure && make -j"$(nproc)" && make install \
    && rm -rf /tmp/verilator

# Spike. We use only its stable CLI (-l --log-commits), never its C++ internals,
# which upstream explicitly documents as a non-public API.
# v1.1.0's fesvr sources omit an explicit <cstdint> include; GCC 13 (Ubuntu 24.04)
# no longer pulls it in transitively, so command_t::payload() fails to parse.
# Force-including <cstdint> is a compiler-compat workaround only - it does not
# touch upstream source or change the pinned v1.1.0 semantics.
#
# --enable-commitlog IS MANDATORY and is NOT the default. Without it, Spike
# refuses every `-l --log-commits` request with "Commit logging support has not
# been properly enabled" and emits no commit lines at all. That silently guts
# the entire trace-comparison verification strategy: parse_spike would return an
# empty list for every program, and an empty Spike trace reads as a truncation
# divergence -- so a broken toolchain would be misdiagnosed as a CPU bug.
# A build without this flag still passes `spike --help`, which is exactly why
# tools-check now asserts commit logging specifically.
RUN git clone --depth 1 --branch ${SPIKE_TAG} https://github.com/riscv-software-src/riscv-isa-sim /tmp/spike \
    && mkdir /tmp/spike/build && cd /tmp/spike/build \
    && CXXFLAGS="-include cstdint" ../configure --prefix=/usr/local --enable-commitlog \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/spike

WORKDIR /work
