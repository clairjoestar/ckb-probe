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
It tracks five core RocksDB operations (GET/PUT/WRITE/ITER_NEW/TXN_COMMIT) \
via uprobe/uretprobe, reports QPS, latency percentiles, bytes/s, and \
detects anomalies using EWMA baseline learning.\n\n\
Testnet only. Never use with mainnet.",
    after_help = "\
EXAMPLES:
    # Environment check
    sudo ckb-probe check --binary ./ckb --pid $(pgrep -x ckb)

    # Symbol analysis
    ckb-probe symbols ./ckb --json

    # RocksDB monitoring (default table)
    sudo ckb-probe rocksdb --binary ./ckb --pid $(pgrep -x ckb)

    # Histogram + slow operations
    sudo ckb-probe rocksdb --binary ./ckb --pid $(pgrep -x ckb) --histogram
    sudo ckb-probe rocksdb --binary ./ckb --pid $(pgrep -x ckb) --slow --threshold 1000

    # JSON output (pipe to jq or monitoring pipeline)
    sudo ckb-probe rocksdb --binary ./ckb --pid $(pgrep -x ckb) --json"
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
    /// uprobe/kprobe/tracepoint probes to validate eBPF feasibility
    /// and collects 3 seconds of live events.
    #[command(
        after_help = "\
EXAMPLES:
    ckb-probe check                            # 8-point environment check
    ckb-probe check --binary ./ckb             # + symbol verification
    ckb-probe check --binary ./ckb --pid 1234  # + eBPF probe validation + live events
    ckb-probe check --binary ./ckb --pid 1234 --probe uprobe  # uprobe only"
    )]
    Check(CheckArgs),

    /// Analyse a CKB binary for uprobe-attachable symbols.
    ///
    /// Parses the ELF symbol table, detects RocksDB linkage method
    /// (static vs dynamic), and classifies every tracked function
    /// into Tier 1 (C API, stable) / Tier 2 (Rust mangled) / Tier 3
    /// (inlined/LTO-eliminated).
    #[command(
        after_help = "\
EXAMPLES:
    ckb-probe symbols ./ckb                    # human-readable report
    ckb-probe symbols ./ckb --json             # machine-readable JSON
    ckb-probe symbols ./ckb --tier 1           # Tier 1 only
    ckb-probe symbols ./ckb --filter transaction  # filter by keyword
    ckb-probe symbols ./ckb -v                 # verbose (addresses, sizes)"
    )]
    Symbols(SymbolsArgs),

    /// Monitor RocksDB operations on a live CKB node via eBPF.
    ///
    /// Attaches uprobe/uretprobe to 5 core RocksDB functions and
    /// reports real-time QPS, latency percentiles (P50/P99), and
    /// bytes/s throughput. Includes EWMA anomaly detection with
    /// 5-minute baseline warmup.
    ///
    /// Four output modes: default table, --histogram, --slow, --json.
    /// Auto-reconnects if CKB process restarts (S-4).
    #[command(
        after_help = "\
EXAMPLES:
    # Default stats table (1s refresh)
    sudo ckb-probe rocksdb --binary ./ckb --pid 1234

    # Latency distribution histogram
    sudo ckb-probe rocksdb --binary ./ckb --pid 1234 --histogram

    # Slow operations log (threshold 1ms)
    sudo ckb-probe rocksdb --binary ./ckb --pid 1234 --slow --threshold 1000

    # JSON output for downstream pipelines
    sudo ckb-probe rocksdb --binary ./ckb --pid 1234 --json --interval 5

    # Extreme P-3 stress test (every op becomes an event)
    sudo ckb-probe rocksdb --binary ./ckb --pid 1234 --slow --threshold 1

EXIT CODES:
    0    Normal exit (Ctrl+C)
    1    Target process exited (S-4: will auto-reconnect if restarted)
    2    Argument error"
    )]
    Rocksdb(RocksdbArgs),
}

#[derive(clap::Args, Debug)]
pub struct CheckArgs {
    /// Path to the CKB binary (enables symbol check + eBPF validation).
    #[arg(long, value_name = "PATH")]
    pub binary: Option<String>,

    /// Target CKB process PID (enables eBPF probe validation).
    /// Requires --binary.
    #[arg(long, value_name = "PID")]
    pub pid: Option<u32>,

    /// Probe type for eBPF validation: uprobe, kprobe, tracepoint, all.
    #[arg(long, default_value = "all", value_name = "TYPE",
          help = "Probe type to validate [possible values: uprobe, kprobe, tracepoint, all]")]
    pub probe: String,
}

#[derive(clap::Args, Debug)]
pub struct SymbolsArgs {
    /// Path to the CKB binary to analyse.
    #[arg(value_name = "CKB_BINARY")]
    pub binary: PathBuf,

    /// Output in JSON format (machine-readable).
    #[arg(long, help = "Output in JSON format for downstream tools")]
    pub json: bool,

    /// Show all details (mangled names, virtual addresses, symbol sizes).
    #[arg(short, long)]
    pub verbose: bool,

    /// Filter output by case-insensitive substring.
    #[arg(long, value_name = "PATTERN", help = "Filter symbols by substring match")]
    pub filter: Option<String>,

    /// Only show a specific tier (1, 2, or 3).
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u8).range(1..=3),
          help = "Show only Tier N symbols [1=C API, 2=Rust mangled, 3=inlined]")]
    pub tier: Option<u8>,
}

#[derive(clap::Args, Debug)]
pub struct RocksdbArgs {
    /// Path to the CKB binary.
    #[arg(long, value_name = "PATH")]
    pub binary: String,

    /// Target CKB process PID.
    #[arg(long, value_name = "PID")]
    pub pid: u32,

    /// Show slow operations log instead of stats table.
    /// Only operations exceeding --threshold are captured via RingBuf.
    #[arg(long, help = "Slow operation capture mode (RingBuf, filtered by --threshold)")]
    pub slow: bool,

    /// Show latency distribution histogram (log2 buckets).
    #[arg(long, help = "Show per-operation latency histogram below stats table")]
    pub histogram: bool,

    /// Output in JSON format (one JSON object per cycle).
    #[arg(long, help = "Machine-readable JSON output (JSONL, pipe to jq)")]
    pub json: bool,

    /// Slow operation threshold in microseconds.
    /// Only operations with latency > threshold trigger RingBuf events.
    /// Use 1000 (1ms) for normal monitoring, 1 for P-3 extreme stress test.
    #[arg(long, default_value = "1000", value_name = "MICROSECONDS")]
    pub threshold: u64,

    /// Stats refresh interval in seconds.
    #[arg(long, default_value = "1", value_name = "SECONDS")]
    pub interval: u64,
}
