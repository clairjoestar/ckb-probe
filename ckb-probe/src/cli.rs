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
ckb-probe check                            # environment check\n  \
ckb-probe check --binary ./ckb --pid 1234  # + eBPF probe validation\n  \
ckb-probe symbols ./ckb                    # analyse binary symbols\n  \
ckb-probe symbols ./ckb --json             # machine-readable JSON"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Check environment and validate eBPF probes.
    ///
    /// Verifies kernel version, BPF config, BTF support, permissions,
    /// uprobe availability, CKB process, and binary symbols.
    /// When --binary and --pid are both provided, also attaches
    /// uprobe/kprobe/tracepoint probes to validate eBPF feasibility.
    Check(CheckArgs),

    /// Analyse a CKB binary for uprobe-attachable symbols.
    ///
    /// Parses the ELF symbol table, detects RocksDB linkage method,
    /// and classifies every tracked function into Tier 1 / 2 / 3.
    Symbols(SymbolsArgs),

    /// Monitor RocksDB operations on a live CKB node via eBPF.
    ///
    /// Attaches uprobe/uretprobe to 5 core RocksDB functions and
    /// reports real-time QPS, latency percentiles, and slow operations.
    Rocksdb(RocksdbArgs),
}

#[derive(clap::Args, Debug)]
pub struct CheckArgs {
    /// Path to the CKB binary (enables symbol check + eBPF validation).
    #[arg(long, value_name = "CKB_BINARY")]
    pub binary: Option<String>,

    /// Target CKB process PID (enables eBPF probe validation).
    /// Requires --binary.
    #[arg(long)]
    pub pid: Option<u32>,

    /// Probe type for eBPF validation: uprobe, kprobe, tracepoint, all.
    #[arg(long, default_value = "all")]
    pub probe: String,
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

#[derive(clap::Args, Debug)]
pub struct RocksdbArgs {
    /// Path to the CKB binary.
    #[arg(long, value_name = "CKB_BINARY")]
    pub binary: String,

    /// Target CKB process PID.
    #[arg(long)]
    pub pid: u32,

    /// Show slow operations log instead of stats table.
    #[arg(long)]
    pub slow: bool,

    /// Show latency distribution histogram.
    #[arg(long)]
    pub histogram: bool,

    /// Output in JSON format.
    #[arg(long)]
    pub json: bool,

    /// Slow operation threshold in microseconds.
    #[arg(long, default_value = "1000", value_name = "μs")]
    pub threshold: u64,

    /// Stats refresh interval in seconds.
    #[arg(long, default_value = "1", value_name = "SECS")]
    pub interval: u64,
}
