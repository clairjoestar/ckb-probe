//! ckb-probe-common: shared type definitions used by both the user-space
//! control program and the BPF program via ckb-probe-ebpf.

#![cfg_attr(not(feature = "user"), no_std)]

#[cfg(feature = "user")]
use serde::{Deserialize, Serialize};

// ────────────────────────────────────────────────────────────────────
// eBPF shared types (used by both kernel-space and user-space)
// ────────────────────────────────────────────────────────────────────

/// Uprobe latency event — sent from BPF to userspace via PerfEventArray.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct UprobeLatencyEvent {
    pub pid: u32,
    pub tid: u32,
    pub func_id: u32,
    pub latency_ns: u64,
    pub ts: u64,
}

/// TCP kprobe event.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TcpEvent {
    pub pid: u32,
    pub tid: u32,
    pub sport: u16,
    pub dport: u16,
    pub saddr: u32,
    pub daddr: u32,
    pub bytes: u32,
    pub direction: u8, // 0 = send, 1 = recv
    pub _pad: [u8; 3],
    pub ts: u64,
}

/// Syscall tracepoint event.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SyscallEvent {
    pub pid: u32,
    pub tid: u32,
    pub syscall_nr: u64,
    pub ts: u64,
}

/// RocksDB function identifier for uprobe demuxing.
#[repr(u32)]
#[derive(Clone, Copy)]
pub enum RocksDbFunc {
    GetPinnedCf = 1,
    Put = 2,
    Delete = 3,
    Write = 4,
    NewIteratorCf = 5,
    MultiGetCf = 6,
    TransactionPutCf = 7,
    TransactionCommit = 8,
}

/// Maximum func_id + 1 (for array sizing).
pub const MAX_FUNC_ID: u32 = 9;

/// Number of log2 histogram buckets (covers 0 .. 2^63 ns).
pub const HIST_BUCKETS: u32 = 64;

/// Per-operation aggregated statistics (stored in PerCpuArray, one per func_id).
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct OpStats {
    pub count: u64,
    pub total_ns: u64,
    pub min_ns: u64,
    pub max_ns: u64,
    /// Bytes processed by this operation (only populated where the BPF probe
    /// can extract a size argument; 0 means "not tracked").
    pub bytes_total: u64,
}

// Safety: OpStats is #[repr(C)] with only u64 fields, safe to read from raw bytes.
#[cfg(feature = "user")]
unsafe impl aya::Pod for OpStats {}

/// Slow operation event — emitted when latency exceeds threshold.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SlowEvent {
    pub pid: u32,
    pub tid: u32,
    pub func_id: u32,
    pub latency_ns: u64,
    /// Operation size in bytes (0 if unknown for this op type).
    pub size: u64,
    pub ts: u64,
}

// ════════════════════════════════════════════════════════════════════
// Everything below requires std (userspace only)
// ════════════════════════════════════════════════════════════════════

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
#[cfg(feature = "user")]
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum SymbolTier {
    #[serde(rename = "tier1")]
    Tier1,
    #[serde(rename = "tier2")]
    Tier2,
    #[serde(rename = "tier3")]
    Tier3,
}

#[cfg(feature = "user")]
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
#[cfg(feature = "user")]
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

#[cfg(feature = "user")]
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
#[cfg(feature = "user")]
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

#[cfg(feature = "user")]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RocksdbLinkage {
    #[serde(rename = "static")]
    Static,
    #[serde(rename = "dynamic")]
    Dynamic,
    #[serde(rename = "unknown")]
    Unknown,
}

#[cfg(feature = "user")]
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

#[cfg(feature = "user")]
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

#[cfg(feature = "user")]
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
#[cfg(feature = "user")]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackedMissing {
    pub path: String,
    pub description: String,
    /// Why we expected it to be missing.
    pub reason: String,
}

#[cfg(feature = "user")]
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
#[cfg(feature = "user")]
pub struct ProbeTargets;

#[cfg(feature = "user")]
impl ProbeTargets {
    /// Tier 1: RocksDB C API functions (`extern "C"`, no mangling).
    pub fn tier1() -> Vec<Tier1Target> {
        vec![
            t1("rocksdb_get", "Generic point read"),
            t1("rocksdb_get_cf", "Point read with Column Family"),
            t1("rocksdb_get_pinned", "Pinned point read (zero-copy)"),
            t1(
                "rocksdb_get_pinned_cf",
                "Pinned read with CF — CKB primary read path",
            ),
            t1("rocksdb_put", "Generic single write"),
            t1("rocksdb_put_cf", "Single write with Column Family"),
            t1("rocksdb_delete", "Generic single delete"),
            t1("rocksdb_delete_cf", "Single delete with Column Family"),
            t1("rocksdb_write", "WriteBatch atomic commit"),
            t1("rocksdb_multi_get_cf", "Multi-key batch read with CF"),
            t1(
                "rocksdb_transaction_put_cf",
                "Transaction write with CF — CKB primary write path",
            ),
            t1(
                "rocksdb_transaction_delete_cf",
                "Transaction delete with CF",
            ),
            t1("rocksdb_transaction_get_cf", "Transaction read with CF"),
            t1("rocksdb_transaction_commit", "Transaction commit"),
            t1(
                "rocksdb_optimistictransaction_begin",
                "Begin optimistic transaction",
            ),
            t1("rocksdb_create_iterator_cf", "Create iterator with CF"),
            t1("rocksdb_iter_seek", "Iterator seek to key"),
            t1("rocksdb_iter_seek_to_first", "Iterator seek to first entry"),
            t1("rocksdb_iter_next", "Iterator advance"),
            t1("rocksdb_iter_destroy", "Destroy iterator"),
        ]
    }

    /// Tier 2: Rust cross-crate public functions (mangled).
    pub fn tier2() -> Vec<Tier2Target> {
        vec![
            t2(
                "ckb_network::network::NetworkService::start",
                "P2P service startup",
                SymbolCategory::P2pNetwork,
            ),
            t2(
                "ckb_network::protocols::CKBHandler::received",
                "Protocol message received callback",
                SymbolCategory::P2pNetwork,
            ),
            t2(
                "tentacle::service::ServiceControl::send_message_to",
                "Send message to a specific peer",
                SymbolCategory::P2pNetwork,
            ),
            t2(
                "tentacle::service::ServiceControl::disconnect",
                "Disconnect a peer",
                SymbolCategory::P2pNetwork,
            ),
            t2(
                "ckb_sync::synchronizer::Synchronizer::received",
                "Sync protocol message handler",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::synchronizer::Synchronizer::try_process",
                "Sync message dispatch",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::relayer::Relayer::received",
                "Relay protocol message handler",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::synchronizer::headers_process::HeadersProcess::execute",
                "Process received headers",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::synchronizer::block_process::BlockProcess::execute",
                "Process received block",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::synchronizer::block_fetcher::BlockFetcher::fetch",
                "Decide which blocks to fetch",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_sync::relayer::compact_block_process::CompactBlockProcess::execute",
                "Process compact block relay",
                SymbolCategory::Sync,
            ),
            t2(
                "ckb_chain::chain_service::ChainService::process_block",
                "Chain service block processing entry",
                SymbolCategory::ChainService,
            ),
            t2(
                "ckb_chain::chain_controller::ChainController::asynchronous_process_remote_block",
                "Async remote block submission",
                SymbolCategory::ChainService,
            ),
            t2(
                "ckb_chain::verify::ConsumeUnverifiedBlocks::verify_block",
                "Full contextual block verification",
                SymbolCategory::ChainService,
            ),
            t2(
                "ckb_store::db::ChainDB::get_block",
                "High-level block retrieval",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_store::transaction::StoreTransaction::insert_block",
                "Write raw block data to DB",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_store::transaction::StoreTransaction::attach_block",
                "Build main-chain indexes for a block",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_store::transaction::StoreTransaction::commit",
                "Atomic commit of store transaction",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_db::db::RocksDB::get_pinned",
                "Low-level pinned read wrapper",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_freezer::freezer::Freezer::freeze",
                "Migrate old blocks to cold storage",
                SymbolCategory::Storage,
            ),
            t2(
                "ckb_freezer::freezer::Freezer::retrieve",
                "Read block from cold storage",
                SymbolCategory::Storage,
            ),
        ]
    }

    /// Tier 3: Functions expected to be absent in release builds.
    pub fn tier3_expected_missing() -> Vec<Tier3Target> {
        vec![
            t3(
                "ckb_network::compress::compress",
                "Snappy compression",
                "inlined in release",
            ),
            t3(
                "ckb_network::compress::decompress",
                "Snappy decompression",
                "inlined in release",
            ),
            t3(
                "ckb_store::cache::StoreCache::get_header",
                "LRU cache header read",
                "inlined in release",
            ),
            t3(
                "ckb_sync::types::SyncShared::insert_new_block",
                "Crate-internal helper",
                "inlined in release",
            ),
            t3(
                "ckb_sync::types::SyncShared::is_initial_block_download",
                "IBD check flag",
                "inlined in release",
            ),
            t3(
                "ckb_chain::utils::orphan_block_pool::OrphanBlockPool::insert",
                "Orphan pool insert",
                "crate-internal",
            ),
            t3(
                "ckb_chain::utils::orphan_block_pool::OrphanBlockPool::search_orphan_leader",
                "Orphan pool search",
                "crate-internal",
            ),
            t3(
                "ckb_network::peer_registry::PeerRegistry::accept",
                "Accept inbound peer",
                "may be inlined in official release",
            ),
            t3(
                "ckb_network::peer_registry::PeerRegistry::try_outbound_peer",
                "Attempt outbound connection",
                "may be inlined",
            ),
            t3(
                "ckb_network::peer_registry::PeerRegistry::remove",
                "Remove peer from registry",
                "may be inlined",
            ),
            t3(
                "tentacle::service::ServiceControl::filter_broadcast",
                "Filtered broadcast helper",
                "may be inlined in official release",
            ),
            t3(
                "ckb_store::db::ChainDB::get_block_header",
                "Block header retrieval",
                "may be inlined",
            ),
        ]
    }
}

// ── helper constructors ──

#[cfg(feature = "user")]
pub struct Tier1Target {
    pub symbol: &'static str,
    pub description: &'static str,
}

#[cfg(feature = "user")]
pub struct Tier2Target {
    pub rust_path: &'static str,
    pub description: &'static str,
    pub category: SymbolCategory,
}

#[cfg(feature = "user")]
pub struct Tier3Target {
    pub rust_path: &'static str,
    pub description: &'static str,
    pub expected_reason: &'static str,
}

#[cfg(feature = "user")]
fn t1(symbol: &'static str, description: &'static str) -> Tier1Target {
    Tier1Target {
        symbol,
        description,
    }
}

#[cfg(feature = "user")]
fn t2(rust_path: &'static str, description: &'static str, category: SymbolCategory) -> Tier2Target {
    Tier2Target {
        rust_path,
        description,
        category,
    }
}

#[cfg(feature = "user")]
fn t3(
    rust_path: &'static str,
    description: &'static str,
    expected_reason: &'static str,
) -> Tier3Target {
    Tier3Target {
        rust_path,
        description,
        expected_reason,
    }
}
