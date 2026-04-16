# syntax=docker/dockerfile:1.6
#
# Single-container ckb-probe case study image.
#   Stage 1: build ckb-probe (userspace + eBPF) + db_bench
#   Stage 2: minimal runtime
#
# CKB binary is NOT included in the image. Mount it from the host:
#   -v /path/to/ckb:/path/to/ckb:ro -e CKB_BIN=/path/to/ckb
#
# Build:
#   docker build -f docker/Dockerfile -t ckb-probe:latest .

# ═══════════════════════════════════════════════════════════════
# Stage 1 — build ckb-probe
# ═══════════════════════════════════════════════════════════════
FROM rust:latest AS probe-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        llvm \
        libelf-dev \
        zlib1g-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install bpf-linker --locked
RUN rustup install nightly && \
    rustup component add rust-src --toolchain nightly

WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY .cargo/ .cargo/
COPY xtask/ xtask/
COPY ckb-probe/ ckb-probe/
COPY ckb-probe-common/ ckb-probe-common/
COPY ckb-probe-ebpf/ ckb-probe-ebpf/

RUN cargo xtask build-ebpf --release && \
    cargo build --release -p ckb-probe

# Build db_bench from RocksDB source (needed by demo-stress)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgflags-dev libsnappy-dev liblz4-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch v9.10.0 https://github.com/facebook/rocksdb.git /tmp/rocksdb \
    && cd /tmp/rocksdb \
    && make -j$(nproc) db_bench \
    && cp db_bench /usr/local/bin/db_bench \
    && rm -rf /tmp/rocksdb

# ═══════════════════════════════════════════════════════════════
# Stage 2 — runtime
# ═══════════════════════════════════════════════════════════════
FROM ubuntu:24.04

# Runtime tools needed by scripts (P-1~P-4, demos, case studies)
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        sysstat \
        curl \
        jq \
        procps \
        tar \
        gzip \
        zstd \
        unzip \
        coreutils \
        grep \
        sed \
        gawk \
        iproute2 \
        lsof \
        ca-certificates \
        libgflags2.2 \
        libsnappy1v5 \
        liblz4-1 \
        libzstd1 \
    && rm -rf /var/lib/apt/lists/*

# ckb-probe binaries
COPY --from=probe-builder /workspace/target/release/ckb-probe \
                          /usr/local/bin/ckb-probe
COPY --from=probe-builder \
    /workspace/ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf \
    /opt/ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf

# db_bench for demo-stress
COPY --from=probe-builder /usr/local/bin/db_bench /usr/local/bin/db_bench

# All scripts (perf / demo / case / stability)
COPY docker/scripts/      /opt/scripts/
COPY docker/ckb-config/   /opt/ckb-config/
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/README.md     /opt/README.md

RUN find /opt/scripts -name "*.sh" -exec chmod +x {} + \
    && chmod +x /entrypoint.sh

# ckb-probe looks up its eBPF binary from cwd as a relative path:
#   ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf
WORKDIR /opt

# Default target dirs (host-volume bound)
VOLUME ["/data", "/tmp/perf-run"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["help"]
