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
