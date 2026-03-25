*Thinking...*

> The user wants me to actually implement the Week 2 tasks from the project proposal. Let me re-read what Week 2 entails:
> 
> **Week 2:** CKB 二进制符号全面侦察——扫描官方 Release 和自编译版本，分析 RocksDB 链接方式，生成分级报告。实现 ckb-probe symbols 子命令。
> 
> So they want the actual code implementation, not a report. Let me provide the complete, working code for the `ckb-probe symbols` subcommand and all related infrastructure.
> 
> This means I need to write:
> 
> 
> - The workspace structure with all Cargo.toml files
> - `ckb-probe-common` crate with shared types
> - `ckb-probe` crate with main entry point, CLI definitions using clap, command registry, and the core symbol analysis implementation
> 
> I'll build production-quality Rust code that parses ELF binaries with goblin, demangles Rust symbols, and detects RocksDB linking patterns.
> 
> Writing the symbol analysis implementation...

# Week 2 具体实现：CKB 二进制符号侦察 + `ckb-probe symbols` 子命令

## 项目目录结构

```
ckb-probe/
├── Cargo.toml                          # workspace root
├── ckb-probe-common/
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs                      # 共享类型定义
├── ckb-probe/
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                     # 入口
│       ├── cli.rs                      # clap CLI 定义
│       └── commands/
│           ├── mod.rs
│           └── symbols.rs              # symbols 子命令核心逻辑
└── ckb-probe-ebpf/                     # Week 3+ 填充，暂为 placeholder
    ├── Cargo.toml
    └── src/
        └── main.rs
```

---

## 1. `Cargo.toml`（workspace root）

```toml
[workspace]
members = [
    "ckb-probe",
    "ckb-probe-common",
    # "ckb-probe-ebpf",  # 暂不纳入 workspace，Week 3 启用
]
resolver = "2"

[workspace.package]
version = "0.1.0"
edition = "2021"
license = "MIT OR Apache-2.0"
repository = "https://github.com/xxx/ckb-probe"
```

---

## 2. `ckb-probe-common/Cargo.toml`

```toml
[package]
name = "ckb-probe-common"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Shared type definitions for ckb-probe"

[dependencies]
serde = { version = "1", features = ["derive"] }
```

---

## 3. `ckb-probe-common/src/lib.rs`

```rust
//! ckb-probe-common: shared type definitions used by both the user-space
//! control program and (in future) the BPF program via ckb-probe-ebpf.

use serde::{Deserialize, Serialize};

// ────────────────────────────────────────────────────────────────────
// Tier / Category enums
// ────────────────────────────────────────────────────────────────────

/// Symbol availability tier.
///
/// * **Tier1** – `extern "C"` symbols (RocksDB C API) that cross the FFI
///   boundary. Unaffected by Rust name-mangling or inlining. Stable across
///   all builds and CKB versions. Ideal uprobe targets.
/// * **Tier2** – Rust cross-crate public functions. Present in most
///   self-compiled release builds, but mangled names include a per-compilation
///   hash suffix, so they must be resolved dynamically per binary.
/// * **Tier3** – Crate-internal or inlined functions that are only visible in
///   debug builds. Not suitable as uprobe targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum SymbolTier {
    #[serde(rename = "tier1")]
    Tier1,
    #[serde(rename = "tier2")]
    Tier2,
    #[serde(rename = "tier3")]
    Tier3,
}

impl std::fmt::Display for SymbolTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Tier1 => write!(f, "Tier 1"),
            Self::Tier2 => write!(f, "Tier 2"),
            Self::Tier3 => write!(f, "Tier 3"),
        }
    }
}

/// Functional category within the CKB architecture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SymbolCategory {
    #[serde(rename = "rocksdb_c_api")]
    RocksdbCApi,
    #[serde(rename = "p2p_network")]
    P2pNetwork,
    #[serde(rename = "sync")]
    Sync,
    #[serde(rename = "chain_service")]
    ChainService,
    #[serde(rename = "storage")]
    Storage,
    #[serde(rename = "tx_pool")]
    TxPool,
    #[serde(rename = "other")]
    Other,
}

impl std::fmt::Display for SymbolCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RocksdbCApi => write!(f, "RocksDB C API"),
            Self::P2pNetwork => write!(f, "P2P Network"),
            Self::Sync => write!(f, "Sync"),
            Self::ChainService => write!(f, "Chain Service"),
            Self::Storage => write!(f, "Storage"),
            Self::TxPool => write!(f, "TxPool"),
            Self::Other => write!(f, "Other"),
        }
    }
}

// ────────────────────────────────────────────────────────────────────
// Symbol info
// ────────────────────────────────────────────────────────────────────

/// Information about a single symbol found during analysis.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolInfo {
    /// Raw (mangled) name from the ELF symbol table.
    pub raw_name: String,
    /// Demangled name (same as `raw_name` for C symbols).
    pub demangled_name: String,
    /// Virtual address inside the binary.
    pub address: u64,
    /// Symbol size in bytes (0 if unknown).
    pub size: u64,
    /// ELF binding: GLOBAL / LOCAL / WEAK.
    pub binding: String,
    /// Tier classification.
    pub tier: SymbolTier,
    /// CKB-architecture category.
    pub category: SymbolCategory,
    /// Whether this symbol is a planned ckb-probe uprobe target.
    pub is_probe_target: bool,
    /// Human-readable description.
    pub description: String,
}

// ────────────────────────────────────────────────────────────────────
// RocksDB linkage
// ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RocksdbLinkage {
    #[serde(rename = "static")]
    Static,
    #[serde(rename = "dynamic")]
    Dynamic,
    #[serde(rename = "unknown")]
    Unknown,
}

impl std::fmt::Display for RocksdbLinkage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Static => write!(f, "Static (bundled into CKB binary)"),
            Self::Dynamic => write!(f, "Dynamic (librocksdb.so)"),
            Self::Unknown => write!(f, "Unknown (no RocksDB symbols found)"),
        }
    }
}

// ────────────────────────────────────────────────────────────────────
// ELF section stats (for verbose output)
// ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ElfOverview {
    pub elf_class: String,
    pub has_symtab: bool,
    pub symtab_count: usize,
    pub has_dynsym: bool,
    pub dynsym_count: usize,
    pub has_dwarf: bool,
    pub strip_status: String,
    /// Counts by binding×type in .symtab.
    pub func_global: usize,
    pub func_local: usize,
    pub func_weak: usize,
    pub func_total: usize,
    pub object_total: usize,
}

// ────────────────────────────────────────────────────────────────────
// Complete report
// ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolReport {
    pub binary_path: String,
    pub file_size: u64,
    pub elf: ElfOverview,
    pub rocksdb_linkage: RocksdbLinkage,
    pub dynamic_deps: Vec<String>,
    pub total_rocksdb_c_symbols: usize,
    pub tier1: Vec<SymbolInfo>,
    pub tier2: Vec<SymbolInfo>,
    pub tier3_missing: Vec<TrackedMissing>,
    pub summary: ReportSummary,
}

/// A tracked symbol that was expected but NOT found in the binary.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackedMissing {
    pub path: String,
    pub description: String,
    /// Why we expected it to be missing.
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReportSummary {
    pub tier1_found: usize,
    pub tier1_tracked: usize,
    pub tier2_found: usize,
    pub tier2_tracked: usize,
    pub tier3_missing_count: usize,
    pub recommendation: String,
}

// ────────────────────────────────────────────────────────────────────
// Probe target registry
// ────────────────────────────────────────────────────────────────────

/// Static registry of known probe targets, grouped by tier.
pub struct ProbeTargets;

impl ProbeTargets {
    /// Tier 1: RocksDB C API functions (`extern "C"`, no mangling).
    pub fn tier1() -> Vec<Tier1Target> {
        vec![
            t1("rocksdb_get",                        "Generic point read"),
            t1("rocksdb_get_cf",                     "Point read with Column Family"),
            t1("rocksdb_get_pinned",                 "Pinned point read (zero-copy)"),
            t1("rocksdb_get_pinned_cf",              "Pinned read with CF — CKB primary read path"),
            t1("rocksdb_put",                        "Generic single write"),
            t1("rocksdb_put_cf",                     "Single write with Column Family"),
            t1("rocksdb_delete",                     "Generic single delete"),
            t1("rocksdb_delete_cf",                  "Single delete with Column Family"),
            t1("rocksdb_write",                      "WriteBatch atomic commit"),
            t1("rocksdb_multi_get_cf",               "Multi-key batch read with CF"),
            t1("rocksdb_transaction_put_cf",         "Transaction write with CF — CKB primary write path"),
            t1("rocksdb_transaction_delete_cf",      "Transaction delete with CF"),
            t1("rocksdb_transaction_get_cf",         "Transaction read with CF"),
            t1("rocksdb_transaction_commit",         "Transaction commit"),
            t1("rocksdb_optimistictransaction_begin", "Begin optimistic transaction"),
            t1("rocksdb_create_iterator_cf",         "Create iterator with CF"),
            t1("rocksdb_iter_seek",                  "Iterator seek to key"),
            t1("rocksdb_iter_seek_to_first",         "Iterator seek to first entry"),
            t1("rocksdb_iter_next",                  "Iterator advance"),
            t1("rocksdb_iter_destroy",               "Destroy iterator"),
        ]
    }

    /// Tier 2: Rust cross-crate public functions (mangled).
    pub fn tier2() -> Vec<Tier2Target> {
        vec![
            t2("ckb_network::network::NetworkService::start",
               "P2P service startup", SymbolCategory::P2pNetwork),
            t2("ckb_network::protocols::CKBHandler::received",
               "Protocol message received callback", SymbolCategory::P2pNetwork),
            t2("tentacle::service::ServiceControl::send_message_to",
               "Send message to a specific peer", SymbolCategory::P2pNetwork),
            t2("tentacle::service::ServiceControl::disconnect",
               "Disconnect a peer", SymbolCategory::P2pNetwork),
            t2("ckb_sync::synchronizer::Synchronizer::received",
               "Sync protocol message handler", SymbolCategory::Sync),
            t2("ckb_sync::synchronizer::Synchronizer::try_process",
               "Sync message dispatch", SymbolCategory::Sync),
            t2("ckb_sync::relayer::Relayer::received",
               "Relay protocol message handler", SymbolCategory::Sync),
            t2("ckb_sync::synchronizer::headers_process::HeadersProcess::execute",
               "Process received headers", SymbolCategory::Sync),
            t2("ckb_sync::synchronizer::block_process::BlockProcess::execute",
               "Process received block", SymbolCategory::Sync),
            t2("ckb_sync::synchronizer::block_fetcher::BlockFetcher::fetch",
               "Decide which blocks to fetch", SymbolCategory::Sync),
            t2("ckb_sync::relayer::compact_block_process::CompactBlockProcess::execute",
               "Process compact block relay", SymbolCategory::Sync),
            t2("ckb_chain::chain_service::ChainService::process_block",
               "Chain service block processing entry", SymbolCategory::ChainService),
            t2("ckb_chain::chain_controller::ChainController::asynchronous_process_remote_block",
               "Async remote block submission", SymbolCategory::ChainService),
            t2("ckb_chain::verify::ConsumeUnverifiedBlocks::verify_block",
               "Full contextual block verification", SymbolCategory::ChainService),
            t2("ckb_store::db::ChainDB::get_block",
               "High-level block retrieval", SymbolCategory::Storage),
            t2("ckb_store::transaction::StoreTransaction::insert_block",
               "Write raw block data to DB", SymbolCategory::Storage),
            t2("ckb_store::transaction::StoreTransaction::attach_block",
               "Build main-chain indexes for a block", SymbolCategory::Storage),
            t2("ckb_store::transaction::StoreTransaction::commit",
               "Atomic commit of store transaction", SymbolCategory::Storage),
            t2("ckb_db::db::RocksDB::get_pinned",
               "Low-level pinned read wrapper", SymbolCategory::Storage),
            t2("ckb_freezer::freezer::Freezer::freeze",
               "Migrate old blocks to cold storage", SymbolCategory::Storage),
            t2("ckb_freezer::freezer::Freezer::retrieve",
               "Read block from cold storage", SymbolCategory::Storage),
        ]
    }

    /// Tier 3: Functions expected to be absent in release builds.
    pub fn tier3_expected_missing() -> Vec<Tier3Target> {
        vec![
            t3("ckb_network::compress::compress",
               "Snappy compression", "inlined in release"),
            t3("ckb_network::compress::decompress",
               "Snappy decompression", "inlined in release"),
            t3("ckb_store::cache::StoreCache::get_header",
               "LRU cache header read", "inlined in release"),
            t3("ckb_sync::types::SyncShared::insert_new_block",
               "Crate-internal helper", "inlined in release"),
            t3("ckb_sync::types::SyncShared::is_initial_block_download",
               "IBD check flag", "inlined in release"),
            t3("ckb_chain::utils::orphan_block_pool::OrphanBlockPool::insert",
               "Orphan pool insert", "crate-internal"),
            t3("ckb_chain::utils::orphan_block_pool::OrphanBlockPool::search_orphan_leader",
               "Orphan pool search", "crate-internal"),
            t3("ckb_network::peer_registry::PeerRegistry::accept",
               "Accept inbound peer", "may be inlined in official release"),
            t3("ckb_network::peer_registry::PeerRegistry::try_outbound_peer",
               "Attempt outbound connection", "may be inlined"),
            t3("ckb_network::peer_registry::PeerRegistry::remove",
               "Remove peer from registry", "may be inlined"),
            t3("tentacle::service::ServiceControl::filter_broadcast",
               "Filtered broadcast helper", "may be inlined in official release"),
            t3("ckb_store::db::ChainDB::get_block_header",
               "Block header retrieval", "may be inlined"),
        ]
    }
}

// ── helper constructors ──

pub struct Tier1Target {
    pub symbol: &'static str,
    pub description: &'static str,
}

pub struct Tier2Target {
    pub rust_path: &'static str,
    pub description: &'static str,
    pub category: SymbolCategory,
}

pub struct Tier3Target {
    pub rust_path: &'static str,
    pub description: &'static str,
    pub expected_reason: &'static str,
}

fn t1(symbol: &'static str, description: &'static str) -> Tier1Target {
    Tier1Target { symbol, description }
}

fn t2(
    rust_path: &'static str,
    description: &'static str,
    category: SymbolCategory,
) -> Tier2Target {
    Tier2Target { rust_path, description, category }
}

fn t3(
    rust_path: &'static str,
    description: &'static str,
    expected_reason: &'static str,
) -> Tier3Target {
    Tier3Target { rust_path, description, expected_reason }
}
```

---

## 4. `ckb-probe/Cargo.toml`

```toml
[package]
name = "ckb-probe"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "Deep observability tool for CKB nodes based on eBPF"

[[bin]]
name = "ckb-probe"
path = "src/main.rs"

[dependencies]
ckb-probe-common = { path = "../ckb-probe-common" }

# ELF parsing
goblin = "0.9"

# Rust symbol demangling
rustc-demangle = "0.1"

# CLI
clap = { version = "4", features = ["derive", "env"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Terminal output
colored = "2"

# Error handling
anyhow = "1"
```

---

## 5. `ckb-probe/src/main.rs`

```rust
mod cli;
mod commands;

use anyhow::Result;
use clap::Parser;
use cli::{Cli, Commands};

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Symbols(args) => commands::symbols::run(args),
        // Week 3+:
        // Commands::Check(args) => commands::check::run(args),
    }
}
```

---

## 6. `ckb-probe/src/cli.rs`

```rust
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "ckb-probe",
    version,
    about = "Deep observability tool for CKB nodes based on eBPF",
    long_about = "\
ckb-probe uses eBPF (uprobe / kprobe / tracepoint) to deliver \
application-semantic, real-time performance insights for CKB full nodes.\n\n\
Quick start:\n  \
ckb-probe symbols ./ckb          # analyse binary symbol availability\n  \
ckb-probe symbols ./ckb --json   # machine-readable JSON output"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Analyse a CKB binary for uprobe-attachable symbols.
    ///
    /// Parses the ELF symbol table, detects RocksDB linkage method,
    /// and classifies every tracked function into Tier 1 / 2 / 3.
    Symbols(SymbolsArgs),
}

#[derive(clap::Args, Debug)]
pub struct SymbolsArgs {
    /// Path to the CKB binary to analyse.
    #[arg(value_name = "CKB_BINARY")]
    pub binary: PathBuf,

    /// Output in JSON format.
    #[arg(long)]
    pub json: bool,

    /// Show all details (mangled names, addresses, descriptions).
    #[arg(short, long)]
    pub verbose: bool,

    /// Filter output by case-insensitive substring.
    #[arg(long, value_name = "PATTERN")]
    pub filter: Option<String>,

    /// Only show a specific tier (1, 2, or 3).
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u8).range(1..=3))]
    pub tier: Option<u8>,
}
```

---

## 7. `ckb-probe/src/commands/mod.rs`

```rust
pub mod symbols;
```

---

## 8. `ckb-probe/src/commands/symbols.rs`（核心实现）

```rust
//! `ckb-probe symbols` — CKB binary symbol reconnaissance.
//!
//! Workflow:
//!   1. Read the binary into memory; parse as ELF via `goblin`.
//!   2. Collect section metadata (.symtab / .dynsym / DWARF / dynamic deps).
//!   3. Build a hashmap   demangled-name → Vec<(raw, addr, size, binding)>.
//!   4. Walk ProbeTargets::tier1/2/3 and classify each into found / missing.
//!   5. Detect RocksDB linkage (static vs dynamic).
//!   6. Emit a `SymbolReport` as coloured terminal text **or** JSON.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use colored::Colorize;
use goblin::elf::sym::{STB_GLOBAL, STB_LOCAL, STB_WEAK, STT_FUNC, STT_OBJECT};
use goblin::elf::Elf;
use rustc_demangle::demangle;

use ckb_probe_common::*;

use crate::cli::SymbolsArgs;

// ════════════════════════════════════════════════════════════════════
// Public entry point
// ════════════════════════════════════════════════════════════════════

pub fn run(args: SymbolsArgs) -> Result<()> {
    let path = &args.binary;
    if !path.exists() {
        bail!("file not found: {}", path.display());
    }

    let buf = fs::read(path)
        .with_context(|| format!("cannot read {}", path.display()))?;

    let elf = match goblin::Object::parse(&buf)
        .with_context(|| "failed to parse ELF")?
    {
        goblin::Object::Elf(e) => e,
        _ => bail!("not an ELF binary — ckb-probe requires a Linux ELF executable"),
    };

    let report = build_report(&elf, path, buf.len() as u64)?;

    if args.json {
        emit_json(&report, &args)
    } else {
        emit_terminal(&report, &args)
    }
}

// ════════════════════════════════════════════════════════════════════
// Analysis core
// ════════════════════════════════════════════════════════════════════

/// Resolved function symbol from .symtab.
struct ResolvedSym {
    raw: String,
    demangled: String,
    addr: u64,
    size: u64,
    binding: Binding,
}

#[derive(Debug, Clone, Copy)]
enum Binding {
    Global,
    Local,
    Weak,
    Other,
}

impl Binding {
    fn from_st(b: u8) -> Self {
        match b {
            STB_GLOBAL => Self::Global,
            STB_LOCAL => Self::Local,
            STB_WEAK => Self::Weak,
            _ => Self::Other,
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            Self::Global => "GLOBAL",
            Self::Local => "LOCAL",
            Self::Weak => "WEAK",
            Self::Other => "OTHER",
        }
    }
}

fn build_report(elf: &Elf, path: &Path, file_size: u64) -> Result<SymbolReport> {
    // ── 1. ELF overview ────────────────────────────────────────────
    let elf_class = format!(
        "ELF {}-bit {}",
        if elf.is_64 { "64" } else { "32" },
        match elf.header.e_machine {
            0x3E => "x86_64",
            0xB7 => "aarch64",
            0x03 => "i386",
            _ => "unknown",
        }
    );

    let has_symtab = !elf.syms.is_empty();
    let symtab_count = elf.syms.len();
    let has_dynsym = !elf.dynsyms.is_empty();
    let dynsym_count = elf.dynsyms.len();

    let has_dwarf = elf.section_headers.iter().any(|sh| {
        elf.shdr_strtab
            .get_at(sh.sh_name)
            .unwrap_or("")
            .starts_with(".debug_")
    });

    let strip_status = match (has_symtab, has_dwarf) {
        (true, true) => "not stripped (full .symtab + DWARF)",
        (true, false) => "debuginfo-stripped (.symtab retained)",
        (false, false) => "fully stripped (no .symtab, no DWARF)",
        (false, true) => "unusual (DWARF present but .symtab missing)",
    }
    .to_string();

    // count by binding × type
    let mut func_global: usize = 0;
    let mut func_local: usize = 0;
    let mut func_weak: usize = 0;
    let mut object_total: usize = 0;

    for sym in elf.syms.iter() {
        match sym.st_type() {
            STT_FUNC => match sym.st_bind() {
                STB_GLOBAL => func_global += 1,
                STB_LOCAL => func_local += 1,
                STB_WEAK => func_weak += 1,
                _ => {}
            },
            STT_OBJECT => object_total += 1,
            _ => {}
        }
    }
    let func_total = func_global + func_local + func_weak;

    let overview = ElfOverview {
        elf_class,
        has_symtab,
        symtab_count,
        has_dynsym,
        dynsym_count,
        has_dwarf,
        strip_status,
        func_global,
        func_local,
        func_weak,
        func_total,
        object_total,
    };

    // ── 2. Dynamic dependencies ────────────────────────────────────
    let dynamic_deps: Vec<String> = elf.libraries.iter().map(|s| s.to_string()).collect();

    // ── 3. RocksDB linkage detection ───────────────────────────────
    let rocksdb_in_dynlibs = dynamic_deps.iter().any(|d| d.contains("rocksdb"));

    let rocksdb_in_dynsym = elf.dynsyms.iter().any(|sym| {
        elf.dynstrtab
            .get_at(sym.st_name)
            .unwrap_or("")
            .starts_with("rocksdb_")
    });

    // count ALL rocksdb_* C-API symbols in .symtab
    let total_rocksdb_c_symbols = elf
        .syms
        .iter()
        .filter(|sym| {
            sym.st_type() == STT_FUNC
                && elf
                    .strtab
                    .get_at(sym.st_name)
                    .unwrap_or("")
                    .starts_with("rocksdb_")
        })
        .count();

    let rocksdb_linkage = if rocksdb_in_dynlibs || rocksdb_in_dynsym {
        RocksdbLinkage::Dynamic
    } else if total_rocksdb_c_symbols > 0 {
        RocksdbLinkage::Static
    } else {
        RocksdbLinkage::Unknown
    };

    // ── 4. Build demangled lookup table from .symtab ───────────────
    // Key: demangled name (for C symbols, identical to raw).
    // Value: list because multiple instantiations can share a path.
    let mut lookup: HashMap<String, Vec<ResolvedSym>> = HashMap::new();

    for sym in elf.syms.iter() {
        if sym.st_type() != STT_FUNC || sym.st_value == 0 {
            continue;
        }
        let raw = match elf.strtab.get_at(sym.st_name) {
            Some(s) if !s.is_empty() => s,
            _ => continue,
        };
        // demangle; for C symbols this is a no-op
        let demangled = format!("{:#}", demangle(raw));
        let binding = Binding::from_st(sym.st_bind());

        lookup
            .entry(demangled.clone())
            .or_default()
            .push(ResolvedSym {
                raw: raw.to_string(),
                demangled,
                addr: sym.st_value,
                size: sym.st_size,
                binding,
            });
    }

    // helper: search by exact key OR by "contains" for Rust paths
    let find_exact = |name: &str| -> Option<&Vec<ResolvedSym>> { lookup.get(name) };

    let find_contains = |substr: &str| -> Vec<&ResolvedSym> {
        lookup
            .values()
            .flatten()
            .filter(|s| s.demangled.contains(substr))
            .collect()
    };

    // ── 5. Tier 1 classification ───────────────────────────────────
    let tier1_targets = ProbeTargets::tier1();
    let mut tier1_found: Vec<SymbolInfo> = Vec::new();

    for t in &tier1_targets {
        if let Some(syms) = find_exact(t.symbol) {
            for s in syms {
                tier1_found.push(SymbolInfo {
                    raw_name: s.raw.clone(),
                    demangled_name: s.demangled.clone(),
                    address: s.addr,
                    size: s.size,
                    binding: s.binding.as_str().to_string(),
                    tier: SymbolTier::Tier1,
                    category: SymbolCategory::RocksdbCApi,
                    is_probe_target: true,
                    description: t.description.to_string(),
                });
            }
        }
    }

    // ── 6. Tier 2 classification ───────────────────────────────────
    let tier2_targets = ProbeTargets::tier2();
    let mut tier2_found: Vec<SymbolInfo> = Vec::new();
    let mut tier2_missing_paths: Vec<(&str, &str)> = Vec::new();

    for t in &tier2_targets {
        let matches = find_contains(t.rust_path);
        if matches.is_empty() {
            tier2_missing_paths.push((t.rust_path, t.description));
        } else {
            for s in matches {
                tier2_found.push(SymbolInfo {
                    raw_name: s.raw.clone(),
                    demangled_name: s.demangled.clone(),
                    address: s.addr,
                    size: s.size,
                    binding: s.binding.as_str().to_string(),
                    tier: SymbolTier::Tier2,
                    category: t.category,
                    is_probe_target: true,
                    description: t.description.to_string(),
                });
            }
        }
    }
    // de-duplicate tier2 by address (one function can match multiple paths)
    tier2_found.sort_by_key(|s| s.address);
    tier2_found.dedup_by_key(|s| s.address);

    // ── 7. Tier 3 (tracked missing) ───────────────────────────────
    let mut tier3_missing: Vec<TrackedMissing> = Vec::new();

    // tier2 targets that were not found → report as missing
    for (path, desc) in &tier2_missing_paths {
        tier3_missing.push(TrackedMissing {
            path: path.to_string(),
            description: desc.to_string(),
            reason: "not found in .symtab (likely inlined or LTO-eliminated)".into(),
        });
    }

    // explicitly expected-missing tier3 targets
    for t in ProbeTargets::tier3_expected_missing() {
        let found = find_contains(t.rust_path);
        if found.is_empty() {
            tier3_missing.push(TrackedMissing {
                path: t.rust_path.to_string(),
                description: t.description.to_string(),
                reason: t.expected_reason.to_string(),
            });
        }
        // if surprisingly found, we simply ignore — it's a bonus
    }

    // ── 8. Summary ─────────────────────────────────────────────────
    let tier1_found_count = tier1_targets
        .iter()
        .filter(|t| find_exact(t.symbol).is_some())
        .count();

    let tier2_found_count = tier2_targets
        .iter()
        .filter(|t| !find_contains(t.rust_path).is_empty())
        .count();

    let recommendation = if tier1_found_count == tier1_targets.len() {
        format!(
            "All {} Tier 1 RocksDB C API symbols found. \
             Ready for uprobe attachment. Stable across CKB versions.",
            tier1_targets.len()
        )
    } else if tier1_found_count == 0 {
        "WARNING: No Tier 1 symbols found. The binary is likely fully stripped. \
         Provide a non-stripped binary or degrade to kprobe+tracepoint."
            .to_string()
    } else {
        format!(
            "Partial Tier 1 coverage ({}/{}). \
             Check whether the binary was custom-stripped.",
            tier1_found_count,
            tier1_targets.len()
        )
    };

    Ok(SymbolReport {
        binary_path: path.display().to_string(),
        file_size,
        elf: overview,
        rocksdb_linkage,
        dynamic_deps,
        total_rocksdb_c_symbols,
        tier1: tier1_found,
        tier2: tier2_found,
        tier3_missing,
        summary: ReportSummary {
            tier1_found: tier1_found_count,
            tier1_tracked: tier1_targets.len(),
            tier2_found: tier2_found_count,
            tier2_tracked: tier2_targets.len(),
            tier3_missing_count: tier3_missing.len(),
            recommendation,
        },
    })
}

// ════════════════════════════════════════════════════════════════════
// JSON output
// ════════════════════════════════════════════════════════════════════

fn emit_json(report: &SymbolReport, args: &SymbolsArgs) -> Result<()> {
    let mut r = report.clone();
    apply_filters(&mut r, args);
    let out = serde_json::to_string_pretty(&r)?;
    println!("{}", out);
    Ok(())
}

// ════════════════════════════════════════════════════════════════════
// Terminal (coloured) output
// ════════════════════════════════════════════════════════════════════

fn emit_terminal(report: &SymbolReport, args: &SymbolsArgs) -> Result<()> {
    let mut r = report.clone();
    apply_filters(&mut r, args);
    let r = r; // rebind immutable

    let w = 68; // box width

    // ── header ─────────────────────────────────────────────────────
    println!();
    println!("{}", "═".repeat(w));
    println!("   {}", "CKB Binary Symbol Analysis Report".bold());
    println!(
        "   Binary: {} ({:.1} MB)",
        r.binary_path,
        r.file_size as f64 / 1_048_576.0
    );
    println!("   Format: {}", r.elf.elf_class);
    println!("{}", "═".repeat(w));

    // ── ELF overview ───────────────────────────────────────────────
    section("ELF Overview");
    kv(
        ".symtab",
        &if r.elf.has_symtab {
            format!("{} ({} symbols)", "✅ Present".green(), r.elf.symtab_count)
        } else {
            format!("{}", "❌ Not found".red())
        },
    );
    kv(
        ".dynsym",
        &if r.elf.has_dynsym {
            format!("{} ({} symbols)", "✅ Present".green(), r.elf.dynsym_count)
        } else {
            format!("{}", "❌ Not found".red())
        },
    );
    kv(
        "DWARF",
        &if r.elf.has_dwarf {
            format!("{}", "✅ Present".green())
        } else {
            format!("{}", "❌ Not found".yellow())
        },
    );
    kv("Strip status", &r.elf.strip_status);

    if args.verbose {
        kv(
            "Functions",
            &format!(
                "{} total (GLOBAL {} / LOCAL {} / WEAK {})",
                r.elf.func_total, r.elf.func_global, r.elf.func_local, r.elf.func_weak
            ),
        );
        kv("Objects", &format!("{}", r.elf.object_total));
    }

    // ── RocksDB linkage ────────────────────────────────────────────
    section("RocksDB Linkage");
    kv("Method", &format!("{}", r.rocksdb_linkage));
    match r.rocksdb_linkage {
        RocksdbLinkage::Static => {
            kv(
                "Evidence",
                &format!(
                    "No librocksdb.so in dynamic deps; {} rocksdb_* in .symtab",
                    r.total_rocksdb_c_symbols
                ),
            );
            kv(
                "Assessment",
                &format!(
                    "{}",
                    "✅ Ideal — C API symbols embedded in binary".green()
                ),
            );
        }
        RocksdbLinkage::Dynamic => {
            kv("Evidence", "librocksdb.so found in dynamic dependencies");
            kv(
                "Assessment",
                &format!(
                    "{}",
                    "✅ Symbols available in shared library".green()
                ),
            );
        }
        RocksdbLinkage::Unknown => {
            kv(
                "Assessment",
                &format!(
                    "{}",
                    "⚠️  No RocksDB symbols found — binary may be fully stripped".red()
                ),
            );
        }
    }

    // ── dynamic deps ───────────────────────────────────────────────
    section("Dynamic Dependencies");
    if r.dynamic_deps.is_empty() {
        println!("  (none — statically linked)");
    } else {
        for chunk in r.dynamic_deps.chunks(3) {
            println!(
                "  {}",
                chunk
                    .iter()
                    .map(|d| format!("{:<26}", d))
                    .collect::<String>()
            );
        }
    }

    // ── tier 1 ─────────────────────────────────────────────────────
    if show_tier(args, 1) {
        section_colored(
            "[Tier 1] Directly uprobe-attachable (extern \"C\", stable)",
            Color::Green,
        );
        if r.tier1.is_empty() {
            println!(
                "  {}",
                "⚠️  No Tier 1 symbols found!".red().bold()
            );
        } else {
            for s in &r.tier1 {
                print!(
                    "  {} {:<46} ",
                    "✅".green(),
                    s.raw_name,
                );
                print!("{:#010x}", s.address);
                println!("  ({} B)", s.size);
                if args.verbose {
                    println!("       └─ {}", s.description.dimmed());
                }
            }
            println!(
                "  {} {} / {} tracked targets found",
                "→".dimmed(),
                r.summary.tier1_found,
                r.summary.tier1_tracked
            );
        }
    }

    // ── tier 2 ─────────────────────────────────────────────────────
    if show_tier(args, 2) {
        section_colored(
            "[Tier 2] Possibly available (Rust mangled, version-bound)",
            Color::Yellow,
        );
        if r.tier2.is_empty() {
            println!("  (no Tier 2 symbols found in this binary)");
        } else {
            for s in &r.tier2 {
                println!("  {} {}", "⚠️ ".yellow(), s.demangled_name.yellow());
                if args.verbose {
                    println!("       ├─ mangled: {}", s.raw_name.dimmed());
                    println!(
                        "       ├─ {:#010x}  ({} B)  [{}]",
                        s.address, s.size, s.binding
                    );
                    println!("       └─ {}", s.description.dimmed());
                }
            }
            println!(
                "  {} {} / {} tracked targets found",
                "→".dimmed(),
                r.summary.tier2_found,
                r.summary.tier2_tracked
            );
        }
    }

    // ── tier 3 (missing) ───────────────────────────────────────────
    if show_tier(args, 3) {
        section_colored(
            "[Tier 3] Unavailable (inlined / stripped / crate-internal)",
            Color::Red,
        );
        if r.tier3_missing.is_empty() {
            println!("  (all tracked symbols found — unusual for release builds)");
        } else {
            let limit = if args.verbose { usize::MAX } else { 15 };
            for (i, m) in r.tier3_missing.iter().enumerate() {
                if i >= limit {
                    println!(
                        "  … and {} more (use -v to show all)",
                        r.tier3_missing.len() - limit
                    );
                    break;
                }
                println!("  {} {} — {}", "❌".red(), m.path, m.reason.dimmed());
                if args.verbose {
                    println!("       └─ {}", m.description.dimmed());
                }
            }
        }
    }

    // ── summary ────────────────────────────────────────────────────
    section("Summary");
    let pct = |n: usize, d: usize| -> usize {
        if d == 0 { 0 } else { n * 100 / d }
    };
    println!(
        "  Tier 1:  {:>2} / {:<2}  ({:>3}%)  {}",
        r.summary.tier1_found,
        r.summary.tier1_tracked,
        pct(r.summary.tier1_found, r.summary.tier1_tracked),
        if r.summary.tier1_found == r.summary.tier1_tracked {
            "READY for uprobe ✅".green().bold().to_string()
        } else if r.summary.tier1_found > 0 {
            "partial coverage ⚠️".yellow().to_string()
        } else {
            "NOT available ❌".red().bold().to_string()
        }
    );
    println!(
        "  Tier 2:  {:>2} / {:<2}  ({:>3}%)  available in this binary",
        r.summary.tier2_found,
        r.summary.tier2_tracked,
        pct(r.summary.tier2_found, r.summary.tier2_tracked),
    );
    println!(
        "  Tier 3:  {} tracked functions not found",
        r.summary.tier3_missing_count
    );
    println!("  Total function symbols:      {}", r.elf.func_total);
    println!(
        "  Total RocksDB C API symbols: {}",
        r.total_rocksdb_c_symbols
    );
    println!();
    println!("  Recommendation:");
    println!("    {}", r.summary.recommendation);
    println!("{}", "═".repeat(w));
    println!();

    Ok(())
}

// ════════════════════════════════════════════════════════════════════
// Filtering helpers
// ════════════════════════════════════════════════════════════════════

fn apply_filters(r: &mut SymbolReport, args: &SymbolsArgs) {
    // substring filter
    if let Some(ref pat) = args.filter {
        let p = pat.to_lowercase();
        r.tier1
            .retain(|s| contains_ci(&s.raw_name, &p) || contains_ci(&s.description, &p));
        r.tier2
            .retain(|s| contains_ci(&s.demangled_name, &p) || contains_ci(&s.description, &p));
        r.tier3_missing
            .retain(|m| contains_ci(&m.path, &p) || contains_ci(&m.description, &p));
    }

    // tier filter
    if let Some(t) = args.tier {
        match t {
            1 => {
                r.tier2.clear();
                r.tier3_missing.clear();
            }
            2 => {
                r.tier1.clear();
                r.tier3_missing.clear();
            }
            3 => {
                r.tier1.clear();
                r.tier2.clear();
            }
            _ => {}
        }
    }
}

fn contains_ci(haystack: &str, needle_lower: &str) -> bool {
    haystack.to_lowercase().contains(needle_lower)
}

fn show_tier(args: &SymbolsArgs, tier: u8) -> bool {
    args.tier.map_or(true, |t| t == tier)
}

// ════════════════════════════════════════════════════════════════════
// Terminal formatting helpers
// ════════════════════════════════════════════════════════════════════

fn section(title: &str) {
    println!();
    println!("── {} {}", title.bold(), "─".repeat(52usize.saturating_sub(title.len())));
}

fn section_colored(title: &str, color: Color) {
    println!();
    let s = match color {
        Color::Green => title.green().bold().to_string(),
        Color::Yellow => title.yellow().bold().to_string(),
        Color::Red => title.red().bold().to_string(),
        _ => title.bold().to_string(),
    };
    println!("── {} ──", s);
}

fn kv(key: &str, val: &str) {
    println!("  {:<16}{}", format!("{}:", key), val);
}

#[allow(dead_code)]
enum Color {
    Green,
    Yellow,
    Red,
    Default,
}

// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use ckb_probe_common::ProbeTargets;

    #[test]
    fn tier1_targets_all_start_with_rocksdb() {
        for t in ProbeTargets::tier1() {
            assert!(
                t.symbol.starts_with("rocksdb_"),
                "Tier 1 target must be a rocksdb C API symbol: {}",
                t.symbol
            );
        }
    }

    #[test]
    fn tier1_count() {
        assert_eq!(ProbeTargets::tier1().len(), 20);
    }

    #[test]
    fn tier2_count() {
        assert_eq!(ProbeTargets::tier2().len(), 21);
    }

    #[test]
    fn tier2_targets_are_rust_paths() {
        for t in ProbeTargets::tier2() {
            assert!(
                t.rust_path.contains("::"),
                "Tier 2 must be a Rust path: {}",
                t.rust_path
            );
        }
    }

    #[test]
    fn demangle_c_symbol_is_identity() {
        let name = "rocksdb_get_pinned_cf";
        let out = format!("{:#}", demangle(name));
        assert_eq!(out, name);
    }

    #[test]
    fn demangle_rust_symbol() {
        // a fabricated but structurally valid mangled name
        let mangled =
            "_ZN8ckb_sync12synchronizer12Synchronizer8received17h0123456789abcdefE";
        let out = format!("{:#}", demangle(mangled));
        assert!(
            out.contains("ckb_sync::synchronizer::Synchronizer::received"),
            "demangled: {}",
            out
        );
    }

    #[test]
    fn filter_ci_works() {
        assert!(contains_ci("rocksdb_GET_pinned_cf", "get"));
        assert!(!contains_ci("rocksdb_put", "get"));
    }
}
```

---

## 9. `ckb-probe-ebpf/`（Placeholder，Week 3 填充）

**`ckb-probe-ebpf/Cargo.toml`：**

```toml
[package]
name = "ckb-probe-ebpf"
version = "0.1.0"
edition = "2021"

# This crate will be built with:
#   cargo +nightly build --target bpfel-unknown-none -Z build-std=core
# It cannot be part of the normal workspace build until Week 3.

[dependencies]
# aya-bpf = { git = "https://github.com/aya-rs/aya", branch = "main" }
# aya-log-ebpf = { git = "https://github.com/aya-rs/aya", branch = "main" }
```

**`ckb-probe-ebpf/src/main.rs`：**

```rust
// Placeholder — Week 3 will implement:
//   1. rocksdb_get_pinned_cf uprobe/uretprobe latency measurement
//   2. Multi-function RocksDB uprobe
//   3. tcp_sendmsg kprobe peer IP:Port extraction
//   4. sys_enter raw tracepoint syscall Top-N

fn main() {
    // This crate targets bpfel-unknown-none and uses #![no_std] + #![no_main].
    // The real entry points are BPF program sections (uprobe, kprobe, etc.).
    // This file will be replaced entirely in Week 3.
    panic!("This is a BPF program stub. Build with bpf target.");
}
```

---

## 10. 构建与运行

```bash
# 构建整个 workspace
cd ckb-probe
cargo build --release

# 基本用法：分析 CKB 二进制
./target/release/ckb-probe symbols /path/to/ckb

# 详细输出
./target/release/ckb-probe symbols /path/to/ckb --verbose

# JSON 输出
./target/release/ckb-probe symbols /path/to/ckb --json

# 只看 Tier 1
./target/release/ckb-probe symbols /path/to/ckb --tier 1

# 过滤含 "transaction" 的符号
./target/release/ckb-probe symbols /path/to/ckb --filter transaction

# JSON + 过滤 + tier，管道给 jq
./target/release/ckb-probe symbols /path/to/ckb --json --tier 1 | jq '.tier1 | length'

# 运行测试
cargo test --workspace
```

---

## 11. 实现说明

**ELF 解析流程（`build_report`）：** 函数首先通过 `goblin` 解析 ELF header、section headers、symbol tables（`.symtab` + `.dynsym`）和动态链接信息。接着遍历 `.symtab` 中所有 `STT_FUNC` 类型且地址非零的符号，对每个符号调用 `rustc_demangle::demangle` 获取可读名称，构建 `HashMap<demangled_name, Vec<ResolvedSym>>`。RocksDB C API 函数由于是 `extern "C"` 声明，demangle 后与原始名称相同（如 `rocksdb_get_pinned_cf`），因此可直接通过精确匹配查找。Rust 函数的 mangled 名称（如 `_ZN8ckb_sync...17h...E`）demangle 后变为 `ckb_sync::synchronizer::Synchronizer::received`，通过子串匹配定位。

**RocksDB 链接方式判定逻辑：** 依次检查三个信号——动态依赖列表中是否包含 `librocksdb.so`；`.dynsym` 中是否有 `rocksdb_*` 前缀符号；`.symtab` 中 `rocksdb_*` 函数的数量。CKB 使用 `librocksdb-sys` 从源码编译 RocksDB 并静态链接，因此在所有已知构建配置下均为 `Static`。

**Tier 分级判定标准：** Tier 1 使用精确匹配（`HashMap::get`），因为 C 符号名固定不变。Tier 2 使用子串匹配（`demangled.contains(rust_path)`），因为 Rust 编译器可能在路径后附加泛型参数或 trait 实现标识。如果某个 Tier 2 目标未找到，它被归入 `tier3_missing` 列表并记录缺失原因。Tier 3 的预期缺失列表（`tier3_expected_missing`）中的符号在 release 构建中通常被内联消除，其缺失属于正常行为。

**过滤机制：** `--filter` 支持大小写不敏感的子串匹配，同时匹配符号名和描述文本。`--tier N` 仅保留指定层级的符号。两个过滤器可叠加使用。过滤在输出阶段（`apply_filters`）执行，不影响 `summary` 中的统计数据（统计反映完整分析结果）。

**终端输出设计：** 使用 `colored` crate 为不同 Tier 着色——Tier 1 绿色表示可用、Tier 2 黄色表示需注意、Tier 3 红色表示不可用。非 verbose 模式下 Tier 3 最多显示 15 条，避免输出过长。`--verbose` 模式额外显示 mangled 名称、精确地址、大小、绑定属性和功能描述。