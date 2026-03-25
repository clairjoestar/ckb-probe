# ckb-probe

Deep observability tool for CKB full nodes, powered by eBPF.

[中文文档](README_zh.md)

## Introduction

ckb-probe leverages eBPF (uprobe / kprobe / tracepoint) to deliver application-semantic, real-time performance insights for CKB full nodes. The `symbols` subcommand is currently implemented, which scans the ELF symbol table of a CKB binary and analyses uprobe-attachable probe targets.

## Features

- **ELF Symbol Parsing**: Parses `.symtab` / `.dynsym` via `goblin`, detects strip status and DWARF debug info automatically.
- **RocksDB Linkage Detection**: Determines whether RocksDB is statically linked (embedded) or dynamically linked (librocksdb.so).
- **Three-tier Symbol Classification**:
  - **Tier 1** — RocksDB C API symbols (`extern "C"`, no mangling), stable across versions, ideal uprobe targets (20 tracked).
  - **Tier 2** — Rust cross-crate public functions (mangled), present in most self-compiled release builds (21 tracked).
  - **Tier 3** — Inlined / LTO-eliminated / crate-internal functions, usually unavailable in release builds (12 tracked).
- **Multiple Output Formats**: Colored terminal report / machine-readable JSON.
- **Flexible Filtering**: Filter by keyword substring or by tier level.

## Build

```bash
# Requires Rust toolchain (rustup recommended)
cargo build --release
```

The binary is located at `target/release/ckb-probe`.

## Usage

### Basic Usage

```bash
# Analyse symbol availability of a CKB binary
ckb-probe symbols /path/to/ckb
```

### Example Output

```
════════════════════════════════════════════════════════════════════════
   CKB Binary Symbol Analysis Report
   Binary: /path/to/ckb (128.5 MB)
   Format: ELF 64-bit x86_64
════════════════════════════════════════════════════════════════════════

── ELF Overview ──────────────────────────────────────────
  .symtab:        ✅ Present (523847 symbols)
  .dynsym:        ✅ Present (12 symbols)
  DWARF:          ❌ Not found
  Strip status:   debuginfo-stripped (.symtab retained)

── RocksDB Linkage ───────────────────────────────────────
  Method:         Static (bundled into CKB binary)
  Evidence:       No librocksdb.so in dynamic deps; 487 rocksdb_* in .symtab
  Assessment:     ✅ Ideal — C API symbols embedded in binary

── [Tier 1] Directly uprobe-attachable (extern "C", stable) ──
  ✅ rocksdb_get                                0x01a2b3c4  (128 B)
  ✅ rocksdb_get_pinned_cf                      0x01a2b4d8  (256 B)
  ...
  → 20 / 20 tracked targets found

── Summary ───────────────────────────────────────────────
  Tier 1:  20 / 20  (100%)  READY for uprobe ✅
  Tier 2:  15 / 21  ( 71%)  available in this binary
  Tier 3:  18 tracked functions not found
```

### Verbose Mode

```bash
# Show mangled names, addresses, sizes, and descriptions
ckb-probe symbols /path/to/ckb --verbose
ckb-probe symbols /path/to/ckb -v
```

### JSON Output

```bash
# Full JSON report
ckb-probe symbols /path/to/ckb --json

# Query with jq
ckb-probe symbols /path/to/ckb --json | jq '.tier1 | length'
ckb-probe symbols /path/to/ckb --json | jq '.rocksdb_linkage'
```

### Filter by Tier

```bash
ckb-probe symbols /path/to/ckb --tier 1   # Tier 1 only (RocksDB C API)
ckb-probe symbols /path/to/ckb --tier 2   # Tier 2 only (Rust functions)
ckb-probe symbols /path/to/ckb --tier 3   # Tier 3 only (unavailable)
```

### Filter by Keyword

```bash
# Case-insensitive substring match
ckb-probe symbols /path/to/ckb --filter transaction
ckb-probe symbols /path/to/ckb --filter iterator --json
ckb-probe symbols /path/to/ckb --tier 1 --filter get
```

### Help

```bash
ckb-probe --help
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
│   └── src/lib.rs              # SymbolTier, SymbolCategory, ProbeTargets, etc.
├── ckb-probe/                  # main CLI binary
│   └── src/
│       ├── main.rs             # entry point
│       ├── cli.rs              # clap CLI definitions
│       └── commands/
│           └── symbols.rs      # symbols subcommand core implementation
└── ckb-probe-ebpf/            # eBPF probe programs (Week 3)
```

## Symbol Tier Reference

| Tier | Source | Stability | Purpose |
|------|------|--------|------|
| Tier 1 | RocksDB C API (`extern "C"`) | Stable across versions | Primary uprobe targets |
| Tier 2 | Rust cross-crate public functions | Hash suffix varies per build | Available in self-compiled builds |
| Tier 3 | Crate-internal / inlined | Usually eliminated in release | Not suitable for uprobe |

## Roadmap

- **Week 2** (done): `ckb-probe symbols` subcommand — binary symbol reconnaissance

## License

MIT OR Apache-2.0
