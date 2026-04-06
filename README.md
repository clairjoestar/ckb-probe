# ckb-probe

Deep observability tool for CKB full nodes, powered by eBPF.

[中文文档](README_zh.md)

## Introduction

ckb-probe leverages eBPF (uprobe / kprobe / tracepoint) to deliver application-semantic, real-time performance insights for CKB full nodes.

- **`check`** — Verifies environment prerequisites, attaches eBPF probes to a live CKB process, and collects real-time events.
- **`symbols`** — Scans the ELF symbol table of a CKB binary and classifies uprobe-attachable probe targets.

## Features

- **ELF Symbol Parsing**: Parses `.symtab` / `.dynsym` via `goblin`, detects strip status and DWARF debug info automatically.
- **RocksDB Linkage Detection**: Determines whether RocksDB is statically linked (embedded) or dynamically linked (librocksdb.so).
- **Three-tier Symbol Classification**:
  - **Tier 1** — RocksDB C API symbols (`extern "C"`, no mangling), stable across versions, ideal uprobe targets (20 tracked).
  - **Tier 2** — Rust cross-crate public functions (mangled), present in most self-compiled release builds (21 tracked).
  - **Tier 3** — Inlined / LTO-eliminated / crate-internal functions, usually unavailable in release builds (12 tracked).
- **Environment Check**: 8-point environment verification with colored pass/fail report.
- **eBPF Probe Validation + Live Event Collection**:
  - RocksDB uprobe/uretprobe latency measurement (entry/return pairing, real-time μs-level latency)
  - TCP kprobe (`tcp_sendmsg` / `tcp_recvmsg`) byte-level monitoring
  - `sys_enter` tracepoint syscall distribution analysis
  - 3-second live event capture with per-probe-type event counts
- **Multiple Output Formats**: Colored terminal report / machine-readable JSON.
- **Flexible Filtering**: Filter by keyword substring or by tier level.

## Build

```bash
# Build eBPF programs + userspace CLI
cargo xtask build

# Build eBPF programs only (requires nightly + BPF target)
cargo xtask build-ebpf

# Build userspace CLI only (requires Rust toolchain)
cargo build --release
```

The binary is located at `target/release/ckb-probe`.

## Usage

### Environment Check

```bash
# Quick environment check (8 items)
ckb-probe check

# + CKB binary symbol verification
ckb-probe check --binary /path/to/ckb
```

### eBPF Validation + Live Events (requires root)

```bash
# Full validation: attach all probes + collect 3s live events
ckb-probe check --binary /path/to/ckb --pid <CKB_PID>

# Validate specific probe type only
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe uprobe
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe kprobe
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe tracepoint
```

Example output:

```
╔══════════════════════════════════════════════════════════════╗
║  ckb-probe eBPF validation                                 ║
╠══════════════════════════════════════════════════════════════╣
  ✅   rocksdb_get_pinned_cf   entry + return attached
  ✅   rocksdb_put             entry + return attached
  ✅   rocksdb_write           entry + return attached
  ✅ uprobe summary            latency pairs: 4/6, Tier 1 symbols: 15/19
  ✅ kprobe tcp_sendmsg_entry  attached to tcp_sendmsg
  ✅ tracepoint sys_enter      attached to raw_syscalls/sys_enter
╚══════════════════════════════════════════════════════════════╝

  ⏳ Collecting live events for 3 seconds...

  [uprobe] pid=3127545 tid=3127553 func=get_pinned_cf            latency=84.7μs
  [uprobe] pid=3127545 tid=3127553 func=write                    latency=44.9μs
  [uprobe] pid=3127545 tid=3127553 func=create_iterator_cf       latency=23.2μs
  [tcp]    pid=3127545 tid=3127556 dir=TX bytes=1471
  [syscall] pid=3127545 tid=3127565 nr=232 (epoll_wait)

  📊 Captured 1873 uprobe, 2 tcp, 621 syscall events in 3s
```

### Symbol Analysis

```bash
# Analyse symbol availability of a CKB binary
ckb-probe symbols /path/to/ckb

# JSON output
ckb-probe symbols /path/to/ckb --json

# Verbose mode (mangled names, addresses, sizes)
ckb-probe symbols /path/to/ckb --verbose

# Filter by tier or keyword
ckb-probe symbols /path/to/ckb --tier 1
ckb-probe symbols /path/to/ckb --filter transaction
```

### Help

```bash
ckb-probe --help
ckb-probe check --help
ckb-probe symbols --help
```

## Tests

```bash
cargo test --workspace
```

## Project Structure

```
ckb-probe/
├── Cargo.toml                  # workspace root
├── ckb-probe-common/           # shared type definitions
│   └── src/lib.rs              # eBPF event types + symbol tier/category/registry
├── ckb-probe/                  # main CLI binary
│   └── src/
│       ├── main.rs             # async entry point (tokio)
│       ├── cli.rs              # clap CLI definitions (check/symbols)
│       └── commands/
│           ├── check.rs        # environment checks + eBPF validation + live event collection
│           └── symbols.rs      # ELF symbol analysis engine
├── ckb-probe-ebpf/             # eBPF kernel programs (no_std)
│   └── src/main.rs             # uprobe/kprobe/tracepoint BPF programs
└── xtask/                      # build helper
    └── src/main.rs             # cargo xtask build-ebpf / build
```

## Symbol Tier Reference

| Tier | Source | Stability | Purpose |
|------|------|--------|------|
| Tier 1 | RocksDB C API (`extern "C"`) | Stable across versions | Primary uprobe targets |
| Tier 2 | Rust cross-crate public functions | Hash suffix varies per build | Available in self-compiled builds |
| Tier 3 | Crate-internal / inlined | Usually eliminated in release | Not suitable for uprobe |

## Environment Check Items

| # | Check | Requirement |
|---|-------|-------------|
| 1 | Kernel version | >= 5.8 |
| 2 | BPF config | CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y, CONFIG_BPF_JIT=y |
| 3 | BTF support | /sys/kernel/btf/vmlinux exists |
| 4 | Permissions | root or CAP_BPF |
| 5 | bpf() syscall | Available (not ENOSYS) |
| 6 | uprobe support | uprobe_events file exists in tracefs |
| 7 | CKB process | Running ckb process detected |
| 8 | CKB symbols | Key RocksDB symbols found in binary (optional) |

## Roadmap

- **Week 2** (done): `ckb-probe symbols` — binary symbol reconnaissance
- **Week 3** (done): eBPF feasibility validation + live event collection + `ckb-probe check`
- **Week 4** (next): RocksDB deep tracing — `ckb-probe rocksdb` with latency histograms, slow operation alerts, and real-time monitoring

## License

MIT OR Apache-2.0
