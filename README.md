# ckb-probe

基于 eBPF 的 CKB 全节点深度可观测性工具。

Deep observability tool for CKB full nodes, powered by eBPF.

---

## 项目简介 / Introduction

ckb-probe 通过 eBPF（uprobe / kprobe / tracepoint）为 CKB 全节点提供应用语义级的实时性能洞察。当前已实现 `symbols` 子命令，用于扫描 CKB 二进制文件的 ELF 符号表，分析 uprobe 可挂载的探针目标。

ckb-probe leverages eBPF (uprobe / kprobe / tracepoint) to deliver application-semantic, real-time performance insights for CKB full nodes. The `symbols` subcommand is currently implemented, which scans the ELF symbol table of a CKB binary and analyses uprobe-attachable probe targets.

## 功能特性 / Features

- **ELF 符号解析 / ELF Symbol Parsing**：基于 `goblin` 解析 `.symtab` / `.dynsym`，自动识别二进制的 strip 状态和 DWARF 调试信息。Parses `.symtab` / `.dynsym` via `goblin`, detects strip status and DWARF debug info automatically.
- **RocksDB 链接方式检测 / RocksDB Linkage Detection**：自动判断 RocksDB 是静态链接（嵌入二进制）还是动态链接（librocksdb.so）。Determines whether RocksDB is statically linked (embedded) or dynamically linked (librocksdb.so).
- **三级符号分类 / Three-tier Symbol Classification**：
  - **Tier 1** — RocksDB C API 符号（`extern "C"`，无 mangling），跨版本稳定，理想的 uprobe 目标（20 个追踪目标）。RocksDB C API symbols (`extern "C"`, no mangling), stable across versions, ideal uprobe targets (20 tracked).
  - **Tier 2** — Rust 跨 crate 公开函数（mangled），存在于大多数自编译 release 版本中（21 个追踪目标）。Rust cross-crate public functions (mangled), present in most self-compiled release builds (21 tracked).
  - **Tier 3** — 被内联/LTO 消除/crate 内部函数，release 构建中通常不可用（12 个追踪目标）。Inlined / LTO-eliminated / crate-internal functions, usually unavailable in release builds (12 tracked).
- **多种输出格式 / Multiple Output Formats**：彩色终端报告 / JSON 机器可读格式。Colored terminal report / machine-readable JSON.
- **灵活过滤 / Flexible Filtering**：按关键字子串过滤、按 Tier 级别过滤。Filter by keyword substring or by tier level.

## 构建 / Build

```bash
# 需要 Rust 工具链（推荐 rustup 安装）
# Requires Rust toolchain (rustup recommended)
cargo build --release
```

构建产物位于 `target/release/ckb-probe`。

The binary is located at `target/release/ckb-probe`.

## 使用方法 / Usage

### 基本用法 / Basic Usage

```bash
# 分析 CKB 二进制的符号可用性
# Analyse symbol availability of a CKB binary
ckb-probe symbols /path/to/ckb
```

### 输出示例 / Example Output

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

### 详细模式 / Verbose Mode

```bash
# 显示 mangled 名称、虚拟地址、符号大小和描述信息
# Show mangled names, addresses, sizes, and descriptions
ckb-probe symbols /path/to/ckb --verbose
ckb-probe symbols /path/to/ckb -v
```

### JSON 输出 / JSON Output

```bash
# 输出完整 JSON 报告 / Full JSON report
ckb-probe symbols /path/to/ckb --json

# 配合 jq 查询 / Query with jq
ckb-probe symbols /path/to/ckb --json | jq '.tier1 | length'
ckb-probe symbols /path/to/ckb --json | jq '.rocksdb_linkage'
```

### 按 Tier 过滤 / Filter by Tier

```bash
ckb-probe symbols /path/to/ckb --tier 1   # Tier 1 only (RocksDB C API)
ckb-probe symbols /path/to/ckb --tier 2   # Tier 2 only (Rust functions)
ckb-probe symbols /path/to/ckb --tier 3   # Tier 3 only (unavailable)
```

### 按关键字过滤 / Filter by Keyword

```bash
# 大小写不敏感 / Case-insensitive substring match
ckb-probe symbols /path/to/ckb --filter transaction
ckb-probe symbols /path/to/ckb --filter iterator --json
ckb-probe symbols /path/to/ckb --tier 1 --filter get
```

### 查看帮助 / Help

```bash
ckb-probe --help
ckb-probe symbols --help
```

## 运行测试 / Tests

```bash
cargo test --workspace
```

## 项目结构 / Project Structure

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

## 符号分级说明 / Symbol Tier Reference

| 级别 / Tier | 来源 / Source | 稳定性 / Stability | 用途 / Purpose |
|------|------|--------|------|
| Tier 1 | RocksDB C API (`extern "C"`) | 跨版本稳定，无 mangling / Stable across versions | 首选 uprobe 目标 / Primary uprobe targets |
| Tier 2 | Rust 跨 crate 公开函数 / Rust cross-crate public functions | 每次编译 hash 后缀不同 / Hash suffix varies per build | 自编译版本可用 / Available in self-compiled builds |
| Tier 3 | crate 内部/内联函数 / Crate-internal / inlined | release 构建中通常被消除 / Usually eliminated in release | 不适合 uprobe / Not suitable for uprobe |

## 路线图 / Roadmap

- **Week 2** (done): `ckb-probe symbols` subcommand — binary symbol reconnaissance

## 许可证 / License

MIT OR Apache-2.0
