use anyhow::Result;
use aya::maps::{PerCpuArray, RingBuf};
use aya::programs::UProbe;
use chrono::{SecondsFormat, Utc};
use ckb_probe_common::{OpStats, SlowEvent, HIST_BUCKETS, MAX_FUNC_ID};
use colored::Colorize;
use std::collections::VecDeque;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::time::{interval, Duration};

use crate::cli::RocksdbArgs;

/// The 5 core monitoring targets:
///   (bpf_entry, bpf_return, elf_symbol, func_id, display_name, has_bytes_tracking).
const MONITOR_PROBES: &[(&str, &str, &str, u32, &str, bool)] = &[
    (
        "rocksdb_get_pinned_cf_entry",
        "rocksdb_get_pinned_cf_return",
        "rocksdb_get_pinned_cf",
        1, // RocksDbFunc::GetPinnedCf
        "GET",
        true, // value size read from returned PinnableSlice (offset 8)
    ),
    (
        "rocksdb_transaction_put_cf_entry",
        "rocksdb_transaction_put_cf_return",
        "rocksdb_transaction_put_cf",
        7, // RocksDbFunc::TransactionPutCf
        "PUT",
        true, // vlen extracted from arg(5) in entry probe
    ),
    (
        "rocksdb_write_entry",
        "rocksdb_write_return",
        "rocksdb_write",
        4, // RocksDbFunc::Write
        "WRITE",
        false, // WriteBatch payload size is internal to the batch object
    ),
    (
        "rocksdb_create_iterator_cf_entry",
        "rocksdb_create_iterator_cf_return",
        "rocksdb_create_iterator_cf",
        5, // RocksDbFunc::NewIteratorCf
        "ITER_NEW",
        false, // no payload
    ),
    (
        "rocksdb_transaction_commit_entry",
        "rocksdb_transaction_commit_return",
        "rocksdb_transaction_commit",
        8, // RocksDbFunc::TransactionCommit
        "TXN_COMMIT",
        true, // sum of PUTs since last commit (per-tid accumulator)
    ),
];

/// Merged per-operation snapshot (computed from PerCpuArray).
#[derive(Clone)]
struct OpSnapshot {
    count: u64,
    total_ns: u64,
    bytes_total: u64,
    /// log2 histogram buckets (64 entries).
    hist: [u64; 64],
}

impl Default for OpSnapshot {
    fn default() -> Self {
        Self {
            count: 0,
            total_ns: 0,
            bytes_total: 0,
            hist: [0u64; 64],
        }
    }
}

// ════════════════════════════════════════════════════════════════
// EWMA-based anomaly detection
// ════════════════════════════════════════════════════════════════

/// Per-op rolling latency baseline using exponentially-weighted moving average.
///
/// * `BASELINE_ALPHA` is the smoothing factor (lower = smoother, slower to react).
/// * `WARMUP_SECS` is the initial period during which the baseline is collected
///   but no anomalies are emitted (avoids false positives at startup).
/// * `SPIKE_MULTIPLIER` is the threshold (avg latency) over baseline that triggers an alert.
/// * `P99_SPIKE_MULTIPLIER` is the  for P99 latency over its baseline.
/// * `ABS_FLOOR_US` is a minimum baseline floor — prevents tiny baselines from
///   producing nonsense ratios and keeps "uniformly slow" workloads detectable.
const BASELINE_ALPHA: f64 = 0.05;
const WARMUP_SECS: u64 = 300;
const SPIKE_MULTIPLIER: f64 = 5.0;
const P99_SPIKE_MULTIPLIER: f64 = 3.0;
const ABS_FLOOR_US: f64 = 50.0;

/// Minimum samples in a 1-second window to use it directly. If fewer, the
/// detector falls back to a 5-second sliding aggregate so that low-QPS ops
/// (PUT / WRITE / TXN_COMMIT during sync) still produce statistically
/// meaningful avg / P99 numbers instead of being silently skipped.
const MIN_SAMPLES_FOR_1S: u64 = 10;
const RING_DEPTH: usize = 5;

/// Per-op absolute P99 caps in μs. Anything above is reported regardless of
/// baseline ratio — catches the "uniformly slow" case where the EWMA has
/// drifted high enough that nothing trips the relative thresholds.
fn hard_p99_cap_us(func_id: u32) -> f64 {
    match func_id {
        1 => 50_000.0,  // GET           — SSD cache miss should be < 5ms
        4 => 50_000.0,  // WRITE         — write to memtable + WAL
        5 => 5_000.0,   // ITER_NEW      — pure CPU/memory work
        7 => 10_000.0,  // PUT (txn)     — in-memory WriteBatch append
        8 => 100_000.0, // TXN_COMMIT    — fsync-bound, allow generous headroom
        _ => f64::INFINITY,
    }
}

#[derive(Default)]
struct AnomalyDetector {
    /// EWMA baseline (avg latency in μs) per func_id.
    baselines: [f64; MAX_FUNC_ID as usize],
    /// EWMA baseline (P99 latency in μs) per func_id.
    baselines_p99: [f64; MAX_FUNC_ID as usize],
}

#[derive(Clone)]
struct Anomaly {
    op: String,
    current_avg_us: f64,
    baseline_avg_us: f64,
    multiplier: f64,
    /// What triggered: any combination of "AVG", "P99", "CAP" joined by "+".
    trigger: String,
    current_p99_us: f64,
    baseline_p99_us: f64,
}

impl AnomalyDetector {
    /// Update baselines and (after warm-up) return any anomalies detected this cycle.
    /// Baselines are *not* updated on anomaly cycles, so a sustained slowdown
    /// keeps firing instead of being absorbed.
    fn observe(
        &mut self,
        attached: &[(u32, &str, bool)],
        cur_avg_us: &[f64],
        cur_p99_us: &[f64],
        elapsed: Duration,
    ) -> Vec<Anomaly> {
        let mut out = Vec::new();
        let warming = elapsed.as_secs() < WARMUP_SECS;

        for &(func_id, display, _) in attached {
            let id = func_id as usize;
            let cur = cur_avg_us[id];
            let cur_p99 = cur_p99_us[id];
            if cur <= 0.0 {
                continue;
            }
            let base = self.baselines[id];
            let base_p99 = self.baselines_p99[id];
            if base == 0.0 {
                self.baselines[id] = cur;
                self.baselines_p99[id] = cur_p99;
                continue;
            }

            // Apply absolute floor so baselines that drift very low don't make
            // every micro-jitter look like a 5× spike, and conversely a "uniformly
            // slow" workload still has a meaningful comparison point.
            let eff_base = base.max(ABS_FLOOR_US);
            let eff_base_p99 = base_p99.max(ABS_FLOOR_US);

            let avg_spike = cur > eff_base * SPIKE_MULTIPLIER;
            let p99_spike = cur_p99 > eff_base_p99 * P99_SPIKE_MULTIPLIER;
            let cap_hit = cur_p99 > hard_p99_cap_us(func_id);

            if !warming && (avg_spike || p99_spike || cap_hit) {
                let mut parts: Vec<&str> = Vec::new();
                if avg_spike {
                    parts.push("AVG");
                }
                if p99_spike {
                    parts.push("P99");
                }
                if cap_hit {
                    parts.push("CAP");
                }
                out.push(Anomaly {
                    op: display.to_string(),
                    current_avg_us: cur,
                    baseline_avg_us: base,
                    multiplier: cur / eff_base,
                    trigger: parts.join("+"),
                    current_p99_us: cur_p99,
                    baseline_p99_us: base_p99,
                });
                // Do NOT update baselines this cycle — otherwise a sustained
                // slowdown gets absorbed within a few samples and the alert
                // silently disappears.
                continue;
            }
            self.baselines[id] = BASELINE_ALPHA * cur + (1.0 - BASELINE_ALPHA) * base;
            self.baselines_p99[id] = BASELINE_ALPHA * cur_p99 + (1.0 - BASELINE_ALPHA) * base_p99;
        }
        out
    }
}

// ════════════════════════════════════════════════════════════════
// Entry point
// ════════════════════════════════════════════════════════════════

pub async fn run(mut args: RocksdbArgs) -> Result<()> {
    let binary = std::fs::canonicalize(&args.binary)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| args.binary.clone());

    let node_label = detect_ckb_version(&binary);

    let ebpf_path =
        std::path::Path::new("ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf");
    if !ebpf_path.exists() {
        anyhow::bail!(
            "eBPF binary not found at {:?}. Run: cargo xtask build-ebpf",
            ebpf_path
        );
    }

    // Global Ctrl+C handler — shared across reconnect cycles.
    let global_running = Arc::new(AtomicBool::new(true));
    {
        let r = global_running.clone();
        tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            r.store(false, Ordering::SeqCst);
        });
    }

    let mut current_pid = args.pid;

    loop {
        args.pid = current_pid;

        // Load BPF (fresh instance each cycle so maps & programs are clean)
        let data = std::fs::read(ebpf_path)?;
        let mut bpf = aya::Ebpf::load(&data)?;

        // Set target PID
        let mut target_pid: aya::maps::HashMap<_, u32, u8> =
            aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
        target_pid.insert(current_pid, 1, 0)?;

        // Set slow threshold (μs → ns)
        let threshold_ns = args.threshold * 1000;
        let mut config: aya::maps::Array<_, u64> =
            aya::maps::Array::try_from(bpf.map_mut("SLOW_THRESHOLD").unwrap())?;
        config.set(0, threshold_ns, 0)?;

        // Attach 5 uprobe pairs
        let mut attached: Vec<(u32, &str, bool)> = Vec::new();
        for &(entry_fn, ret_fn, symbol, func_id, display, has_bytes) in MONITOR_PROBES {
            let uprobe: &mut UProbe = bpf.program_mut(entry_fn).unwrap().try_into()?;
            uprobe.load()?;
            match uprobe.attach(Some(symbol), 0, &binary, Some(current_pid as i32)) {
                Ok(_) => {
                    let uretprobe: &mut UProbe = bpf.program_mut(ret_fn).unwrap().try_into()?;
                    uretprobe.load()?;
                    uretprobe.attach(Some(symbol), 0, &binary, Some(current_pid as i32))?;
                    attached.push((func_id, display, has_bytes));
                    eprintln!("  ✅ attached {}", symbol);
                }
                Err(_) => {
                    eprintln!("  ❌ {} not found in binary, skipping", symbol);
                }
            }
        }

        if attached.is_empty() {
            anyhow::bail!("No RocksDB symbols found in binary — nothing to monitor");
        }

        eprintln!();
        eprintln!(
            "  Monitoring {} operations on PID {} (threshold: {}μs, interval: {}s)",
            attached.len(),
            current_pid,
            args.threshold,
            args.interval,
        );
        eprintln!("  Press Ctrl+C to stop.");
        eprintln!();

        // Per-cycle running flag — set to false on process exit OR Ctrl+C.
        let running = Arc::new(AtomicBool::new(true));

        // S-4: detect target process exit
        let pid_exited = Arc::new(AtomicBool::new(false));
        {
            let r = running.clone();
            let gr = global_running.clone();
            let exited = pid_exited.clone();
            let pid = current_pid;
            tokio::spawn(async move {
                let proc_path = format!("/proc/{}", pid);
                loop {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    if !std::path::Path::new(&proc_path).exists() {
                        exited.store(true, Ordering::SeqCst);
                        r.store(false, Ordering::SeqCst);
                        break;
                    }
                    if !gr.load(Ordering::SeqCst) {
                        r.store(false, Ordering::SeqCst);
                        break;
                    }
                }
            });
        }

        if args.slow {
            run_slow_mode(&mut bpf, &attached, &args, &running).await?;
        } else if args.json {
            run_stats_loop(&mut bpf, &attached, &args, &running, &node_label, true).await?;
        } else {
            run_stats_loop(&mut bpf, &attached, &args, &running, &node_label, false).await?;
        }

        // BPF resources are dropped here when `bpf` goes out of scope.
        drop(bpf);

        if !pid_exited.load(Ordering::SeqCst) {
            // Normal Ctrl+C exit
            break;
        }

        // S-4: process exited — wait for a new CKB process with the same binary.
        eprintln!();
        eprintln!(
            "  {} Target process (PID {}) exited. Waiting for CKB to restart...",
            "⚠".bright_yellow(),
            current_pid,
        );

        match wait_for_new_pid(&binary, &global_running).await {
            Some(new_pid) => {
                eprintln!(
                    "  {} CKB restarted (new PID {}). Reattaching probes...",
                    "✅".green(),
                    new_pid,
                );
                eprintln!();
                current_pid = new_pid;
                // Loop back to reload BPF and reattach
            }
            None => {
                // Ctrl+C during wait
                break;
            }
        }
    }

    Ok(())
}

/// Scan /proc for a process whose exe symlink matches `binary`.
fn find_pid_by_binary(binary: &str) -> Option<u32> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return None;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid_str) = name.to_str() else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };
        let exe_path = format!("/proc/{}/exe", pid);
        if let Ok(target) = std::fs::read_link(&exe_path) {
            if let Ok(canon) = std::fs::canonicalize(&target) {
                if canon.to_string_lossy() == binary {
                    return Some(pid);
                }
            }
            // Also check the raw symlink target (may already be canonical)
            if target.to_string_lossy() == binary {
                return Some(pid);
            }
        }
    }
    None
}

/// Poll for a new CKB process with the given binary, returning its PID.
/// Returns None if Ctrl+C is pressed during the wait.
async fn wait_for_new_pid(binary: &str, running: &Arc<AtomicBool>) -> Option<u32> {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if !running.load(Ordering::SeqCst) {
            return None;
        }
        if let Some(pid) = find_pid_by_binary(binary) {
            return Some(pid);
        }
    }
}

// ════════════════════════════════════════════════════════════════
// Stats table mode (default + --histogram + --json)
// ════════════════════════════════════════════════════════════════

async fn run_stats_loop(
    bpf: &mut aya::Ebpf,
    attached: &[(u32, &str, bool)],
    args: &RocksdbArgs,
    running: &Arc<AtomicBool>,
    node_label: &str,
    json: bool,
) -> Result<()> {
    let mut tick = interval(Duration::from_secs(args.interval));
    let mut prev_snapshots: Vec<OpSnapshot> = vec![OpSnapshot::default(); MAX_FUNC_ID as usize];
    // Ring of historical snapshots (oldest at front). Used to build a
    // RING_DEPTH-second sliding aggregate for low-QPS ops where the 1-second
    // window has too few samples to be statistically meaningful.
    let mut history: VecDeque<Vec<OpSnapshot>> = VecDeque::with_capacity(RING_DEPTH + 1);
    let mut detector = AnomalyDetector::default();
    let start = std::time::Instant::now();

    while running.load(Ordering::SeqCst) {
        tick.tick().await;
        if !running.load(Ordering::SeqCst) {
            break;
        }

        // Read current snapshots from PerCpuArray
        let snapshots = read_all_snapshots(bpf)?;

        // Compute per-op current avg & P99 (μs) for the anomaly detector.
        // For each op, prefer the 1-second window if it has enough samples;
        // otherwise fall back to the RING_DEPTH-second sliding aggregate.
        let mut cur_avg_us = vec![0.0f64; MAX_FUNC_ID as usize];
        let mut cur_p99_us = vec![0.0f64; MAX_FUNC_ID as usize];
        let oldest = history.front();
        for &(func_id, _, _) in attached {
            let id = func_id as usize;

            // 1-second delta vs prev_snapshots
            let dc_1s = snapshots[id].count.saturating_sub(prev_snapshots[id].count);
            let dn_1s = snapshots[id]
                .total_ns
                .saturating_sub(prev_snapshots[id].total_ns);
            let mut delta_hist_1s = [0u64; 64];
            for (i, slot) in delta_hist_1s.iter_mut().enumerate() {
                *slot = snapshots[id].hist[i].saturating_sub(prev_snapshots[id].hist[i]);
            }

            if dc_1s >= MIN_SAMPLES_FOR_1S {
                cur_avg_us[id] = dn_1s as f64 / dc_1s as f64 / 1000.0;
                cur_p99_us[id] = percentile_from_hist(&delta_hist_1s, 99.0) as f64 / 1000.0;
            } else if let Some(old) = oldest {
                // Fall back to RING_DEPTH-second aggregate
                let dc_w = snapshots[id].count.saturating_sub(old[id].count);
                let dn_w = snapshots[id].total_ns.saturating_sub(old[id].total_ns);
                if dc_w > 0 {
                    cur_avg_us[id] = dn_w as f64 / dc_w as f64 / 1000.0;
                    let mut delta_hist_w = [0u64; 64];
                    for (i, slot) in delta_hist_w.iter_mut().enumerate() {
                        *slot = snapshots[id].hist[i].saturating_sub(old[id].hist[i]);
                    }
                    cur_p99_us[id] = percentile_from_hist(&delta_hist_w, 99.0) as f64 / 1000.0;
                }
            } else if dc_1s > 0 {
                // Ring not yet full — use whatever 1s data we have
                cur_avg_us[id] = dn_1s as f64 / dc_1s as f64 / 1000.0;
                cur_p99_us[id] = percentile_from_hist(&delta_hist_1s, 99.0) as f64 / 1000.0;
            }
        }
        let elapsed = start.elapsed();
        let anomalies = detector.observe(attached, &cur_avg_us, &cur_p99_us, elapsed);

        // Maintain the history ring (push current prev_snapshots, drop oldest)
        history.push_back(prev_snapshots.clone());
        while history.len() > RING_DEPTH {
            history.pop_front();
        }

        if json {
            print_json(
                attached,
                &snapshots,
                &prev_snapshots,
                args,
                elapsed,
                &anomalies,
            );
        } else {
            print_table(
                attached,
                &snapshots,
                &prev_snapshots,
                args,
                elapsed,
                node_label,
                &anomalies,
                elapsed.as_secs() < WARMUP_SECS,
            );
            if args.histogram {
                print_histogram(attached, &snapshots, &prev_snapshots);
            }
        }

        prev_snapshots = snapshots;
    }

    eprintln!("\n  Stopped.");
    Ok(())
}

fn read_all_snapshots(bpf: &mut aya::Ebpf) -> Result<Vec<OpSnapshot>> {
    let mut snapshots = vec![OpSnapshot::default(); MAX_FUNC_ID as usize];

    // Read OP_STATS
    let op_stats: PerCpuArray<_, OpStats> = PerCpuArray::try_from(bpf.map("OP_STATS").unwrap())?;
    for func_id in 0..MAX_FUNC_ID {
        if let Ok(per_cpu) = op_stats.get(&func_id, 0) {
            let s = &mut snapshots[func_id as usize];
            for v in per_cpu.iter() {
                s.count += v.count;
                s.total_ns += v.total_ns;
                s.bytes_total += v.bytes_total;
            }
        }
    }

    // Read LATENCY_HIST
    let hist: PerCpuArray<_, u64> = PerCpuArray::try_from(bpf.map("LATENCY_HIST").unwrap())?;
    for func_id in 0..MAX_FUNC_ID {
        for bucket in 0..HIST_BUCKETS {
            let idx = func_id * HIST_BUCKETS + bucket;
            if let Ok(per_cpu) = hist.get(&idx, 0) {
                let total: u64 = per_cpu.iter().sum();
                snapshots[func_id as usize].hist[bucket as usize] = total;
            }
        }
    }

    Ok(snapshots)
}

/// Compute percentile from log2 histogram. Returns value in nanoseconds.
fn percentile_from_hist(hist: &[u64; 64], pct: f64) -> u64 {
    let total: u64 = hist.iter().sum();
    if total == 0 {
        return 0;
    }
    let target = (total as f64 * pct / 100.0).ceil() as u64;
    let mut acc = 0u64;
    for (i, &count) in hist.iter().enumerate() {
        acc += count;
        if acc >= target {
            // Bucket i covers [2^i, 2^(i+1)). Return midpoint.
            if i == 0 {
                return 1;
            }
            let lo = 1u64 << i;
            let hi = 1u64 << (i + 1);
            return (lo + hi) / 2;
        }
    }
    0
}

// ────────────────────────────────────────────────────────────────
// Table rendering — fixed widths to match the main_proj.md spec
// ────────────────────────────────────────────────────────────────

const COL_OP: usize = 10; // "GET       "
const COL_QPS: usize = 5; // "3,241"
const COL_AVG: usize = 7; // "    4.7"
const COL_P50: usize = 7; // "    3.2"
const COL_P99: usize = 7; // "   18.5"
const COL_BYTES: usize = 13; // "  1.2 MB/s  "

/// Inside-border width = sum(content widths) + 5 inner `│` separators
/// + 12 cell-padding spaces (1 left + 1 right per cell × 6 cells).
const INSIDE_W: usize = COL_OP + COL_QPS + COL_AVG + COL_P50 + COL_P99 + COL_BYTES + 5 + 12;
// 10 + 5 + 7 + 7 + 7 + 13 + 5 + 12 = 66

#[allow(clippy::too_many_arguments)]
fn print_table(
    attached: &[(u32, &str, bool)],
    cur: &[OpSnapshot],
    prev: &[OpSnapshot],
    args: &RocksdbArgs,
    elapsed: std::time::Duration,
    node_label: &str,
    anomalies: &[Anomaly],
    warming: bool,
) {
    let uptime = format_duration(elapsed);
    let interval = args.interval;

    // Clear screen and move to top
    print!("\x1B[2J\x1B[H");

    // ── Header (title + sub-header) ──
    let title = format!(" CKB RocksDB Monitor (PID: {}) ", args.pid);
    let pad = INSIDE_W.saturating_sub(title.len());
    let left = pad / 2;
    let right = pad - left;
    println!(
        "{}",
        format!("╭{}{}{}╮", "─".repeat(left), title, "─".repeat(right)).bright_cyan()
    );

    let sub = format!(
        " Uptime: {}   Sampling: {}s   Node: {}",
        uptime, interval, node_label
    );
    let sub_pad = INSIDE_W.saturating_sub(sub.chars().count());
    println!(
        "{}",
        format!("│{}{}│", sub, " ".repeat(sub_pad)).bright_cyan()
    );

    // ── Table head ──
    println!(
        "{}",
        format!(
            "├{}┬{}┬{}┬{}┬{}┬{}┤",
            "─".repeat(COL_OP + 2),
            "─".repeat(COL_QPS + 2),
            "─".repeat(COL_AVG + 2),
            "─".repeat(COL_P50 + 2),
            "─".repeat(COL_P99 + 2),
            "─".repeat(COL_BYTES + 2),
        )
        .bright_cyan()
    );
    println!(
        "{}",
        format!(
            "│ {:<w_op$} │ {:^w_qps$} │ {:^w_avg$} │ {:^w_p50$} │ {:^w_p99$} │ {:^w_bytes$} │",
            "Operation",
            "QPS",
            "Avg(μs)",
            "P50(μs)",
            "P99(μs)",
            "Bytes/s",
            w_op = COL_OP,
            w_qps = COL_QPS,
            w_avg = COL_AVG,
            w_p50 = COL_P50,
            w_p99 = COL_P99,
            w_bytes = COL_BYTES,
        )
        .bright_cyan()
    );
    println!(
        "{}",
        format!(
            "├{}┼{}┼{}┼{}┼{}┼{}┤",
            "─".repeat(COL_OP + 2),
            "─".repeat(COL_QPS + 2),
            "─".repeat(COL_AVG + 2),
            "─".repeat(COL_P50 + 2),
            "─".repeat(COL_P99 + 2),
            "─".repeat(COL_BYTES + 2),
        )
        .bright_cyan()
    );

    // ── Data rows ──
    for &(func_id, display, has_bytes) in attached {
        let id = func_id as usize;
        let delta_count = cur[id].count.saturating_sub(prev[id].count);
        let delta_ns = cur[id].total_ns.saturating_sub(prev[id].total_ns);
        let delta_bytes = cur[id].bytes_total.saturating_sub(prev[id].bytes_total);

        let qps = delta_count / interval.max(1);
        let avg_us = if delta_count > 0 {
            delta_ns as f64 / delta_count as f64 / 1000.0
        } else {
            0.0
        };

        let mut delta_hist = [0u64; 64];
        for (i, slot) in delta_hist.iter_mut().enumerate() {
            *slot = cur[id].hist[i].saturating_sub(prev[id].hist[i]);
        }
        let p50_us = percentile_from_hist(&delta_hist, 50.0) as f64 / 1000.0;
        let p99_us = percentile_from_hist(&delta_hist, 99.0) as f64 / 1000.0;

        let bytes_str = if has_bytes {
            let bps = delta_bytes / interval.max(1);
            format_bytes_per_sec(bps)
        } else {
            "—".to_string()
        };

        println!(
            "│ {:<w_op$} │ {:>w_qps$} │ {:>w_avg$.1} │ {:>w_p50$.1} │ {:>w_p99$.1} │ {:^w_bytes$} │",
            display,
            format_qps(qps),
            avg_us,
            p50_us,
            p99_us,
            bytes_str,
            w_op = COL_OP,
            w_qps = COL_QPS,
            w_avg = COL_AVG,
            w_p50 = COL_P50,
            w_p99 = COL_P99,
            w_bytes = COL_BYTES,
        );
    }

    // ── Bottom border ──
    println!(
        "{}",
        format!(
            "╰{}┴{}┴{}┴{}┴{}┴{}╯",
            "─".repeat(COL_OP + 2),
            "─".repeat(COL_QPS + 2),
            "─".repeat(COL_AVG + 2),
            "─".repeat(COL_P50 + 2),
            "─".repeat(COL_P99 + 2),
            "─".repeat(COL_BYTES + 2),
        )
        .bright_cyan()
    );

    // ── Status / anomaly footer ──
    if !anomalies.is_empty() {
        let now_label = format_clock(elapsed);
        println!();
        println!(
            "{}  ANOMALY DETECTED [{}]",
            "⚠️ ".bright_yellow(),
            now_label
        );
        for a in anomalies {
            println!(
                "  → {} [{}]  avg {:.1}μs (base {:.1}μs, ×{:.1})  p99 {:.1}μs (base {:.1}μs)",
                a.op.bright_red(),
                a.trigger,
                a.current_avg_us,
                a.baseline_avg_us,
                a.multiplier,
                a.current_p99_us,
                a.baseline_p99_us,
            );
        }
        // Try to attribute the spike if WRITE P99 is also elevated.
        if let Some(write_id) = attached
            .iter()
            .find(|p| p.1 == "WRITE")
            .map(|p| p.0 as usize)
        {
            let mut delta_hist = [0u64; 64];
            for (i, slot) in delta_hist.iter_mut().enumerate() {
                *slot = cur[write_id].hist[i].saturating_sub(prev[write_id].hist[i]);
            }
            let write_p99_us = percentile_from_hist(&delta_hist, 99.0) as f64 / 1000.0;
            if write_p99_us > 1000.0 {
                println!(
                    "  → Probable cause: Compaction storm (WRITE P99 = {:.1}ms)",
                    write_p99_us / 1000.0
                );
            }
        }
        println!("  → Run `ckb-probe rocksdb --slow` for slow operation details.");
    } else if warming {
        println!(
            "  Status: {} — Collecting baseline ({}s remaining).",
            "⏳ Warming up".dimmed(),
            WARMUP_SECS.saturating_sub(elapsed.as_secs())
        );
    } else {
        println!(
            "  Status: {} — All latencies within baseline.",
            "✅ Normal".bright_green()
        );
    }
}

fn print_histogram(attached: &[(u32, &str, bool)], cur: &[OpSnapshot], prev: &[OpSnapshot]) {
    println!();
    for &(func_id, display, _) in attached {
        let id = func_id as usize;
        let mut delta_hist = [0u64; 64];
        for (i, slot) in delta_hist.iter_mut().enumerate() {
            *slot = cur[id].hist[i].saturating_sub(prev[id].hist[i]);
        }
        let max_count = *delta_hist.iter().max().unwrap_or(&0);
        if max_count == 0 {
            continue;
        }

        println!("  {} latency distribution:", display.bold());
        let last_nonzero = delta_hist.iter().rposition(|&c| c > 0).unwrap_or(0);
        let start_bucket = delta_hist.iter().position(|&c| c > 0).unwrap_or(0);
        let end = last_nonzero.min(39);
        for (i, &count) in delta_hist
            .iter()
            .enumerate()
            .take(end + 1)
            .skip(start_bucket)
        {
            let label = bucket_label(i);
            let bar_len = (count * 40).checked_div(max_count).unwrap_or(0) as usize;
            let bar: String = "█".repeat(bar_len);
            if count > 0 {
                println!("    {:>8} │{:<40} {}", label, bar.bright_magenta(), count);
            } else {
                println!("    {:>8} │{:<40}", label, "");
            }
        }
        println!();
    }
}

fn print_json(
    attached: &[(u32, &str, bool)],
    cur: &[OpSnapshot],
    prev: &[OpSnapshot],
    args: &RocksdbArgs,
    elapsed: std::time::Duration,
    anomalies: &[Anomaly],
) {
    let mut ops = serde_json::Map::new();

    for &(func_id, display, has_bytes) in attached {
        let id = func_id as usize;
        let delta_count = cur[id].count.saturating_sub(prev[id].count);
        let delta_ns = cur[id].total_ns.saturating_sub(prev[id].total_ns);
        let delta_bytes = cur[id].bytes_total.saturating_sub(prev[id].bytes_total);
        let qps = delta_count / args.interval.max(1);
        let avg_us = if delta_count > 0 {
            delta_ns as f64 / delta_count as f64 / 1000.0
        } else {
            0.0
        };
        let mut delta_hist = [0u64; 64];
        for (i, slot) in delta_hist.iter_mut().enumerate() {
            *slot = cur[id].hist[i].saturating_sub(prev[id].hist[i]);
        }
        let p50_us = percentile_from_hist(&delta_hist, 50.0) as f64 / 1000.0;
        let p99_us = percentile_from_hist(&delta_hist, 99.0) as f64 / 1000.0;

        let mut m = serde_json::Map::new();
        m.insert("qps".into(), serde_json::json!(qps));
        m.insert("avg_us".into(), serde_json::json!(round2(avg_us)));
        m.insert("p50_us".into(), serde_json::json!(round2(p50_us)));
        m.insert("p99_us".into(), serde_json::json!(round2(p99_us)));
        if has_bytes {
            m.insert(
                "bytes_per_sec".into(),
                serde_json::json!(delta_bytes / args.interval.max(1)),
            );
        } else {
            m.insert("bytes_per_sec".into(), serde_json::Value::Null);
        }
        if args.histogram {
            let buckets: Vec<_> = delta_hist
                .iter()
                .enumerate()
                .filter(|(_, &c)| c > 0)
                .map(|(i, &c)| {
                    let lo_ns = if i == 0 { 0u64 } else { 1u64 << i };
                    let lo_us = lo_ns as f64 / 1000.0;
                    serde_json::json!({ "ge_us": round2(lo_us), "count": c })
                })
                .collect();
            m.insert("histogram".into(), serde_json::json!(buckets));
        }
        ops.insert(display.to_string(), serde_json::Value::Object(m));
    }

    let anomalies_json: Vec<_> = anomalies
        .iter()
        .map(|a| {
            serde_json::json!({
                "time": format_clock(elapsed),
                "type": "latency_spike",
                "operation": a.op,
                "trigger": a.trigger,
                "current_avg_us": round2(a.current_avg_us),
                "baseline_avg_us": round2(a.baseline_avg_us),
                "multiplier": round2(a.multiplier),
                "current_p99_us": round2(a.current_p99_us),
                "baseline_p99_us": round2(a.baseline_p99_us),
            })
        })
        .collect();

    let out = serde_json::json!({
        "timestamp": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        "pid": args.pid,
        "uptime_secs": elapsed.as_secs(),
        "operations": ops,
        "anomalies": anomalies_json,
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

// ════════════════════════════════════════════════════════════════
// Slow operations mode (--slow) — box table format
// ════════════════════════════════════════════════════════════════

#[derive(Clone)]
struct SlowRow {
    ts_clock: String,
    op: String,
    latency_us: f64,
    size: u64,
    note: &'static str,
}

async fn run_slow_mode(
    bpf: &mut aya::Ebpf,
    _attached: &[(u32, &str, bool)],
    args: &RocksdbArgs,
    running: &Arc<AtomicBool>,
) -> Result<()> {
    let map = bpf
        .take_map("SLOW_EVENTS")
        .ok_or_else(|| anyhow::anyhow!("SLOW_EVENTS map not found"))?;
    let ring_buf = RingBuf::try_from(map)?;

    // Channel for events from ring buffer reader to the renderer.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<SlowEvent>();

    // RingBuf drops are reported as errors in kernel-side output(),
    // not as lost events in userspace. We track total attempted vs received.
    let total_lost = Arc::new(AtomicU64::new(0));

    // Single reader thread — RingBuf is shared across all CPUs.
    // Poll every 50ms to batch-consume events. No per-event wakeup needed.
    let running2 = running.clone();
    let mut handles = Vec::new();
    {
        let r = running2.clone();
        let txc = tx.clone();
        handles.push(tokio::spawn(async move {
            let mut ring = ring_buf;
            let mut poll = tokio::time::interval(Duration::from_millis(50));
            while r.load(Ordering::SeqCst) {
                poll.tick().await;
                // Drain all available events
                while let Some(item) = ring.next() {
                    if item.len() >= std::mem::size_of::<SlowEvent>() {
                        let event = unsafe { (item.as_ptr() as *const SlowEvent).read_unaligned() };
                        let _ = txc.send(event);
                    }
                }
            }
        }));
    }
    drop(tx);

    // Render loop: keep last N rows + total count, redraw every interval.
    const MAX_ROWS: usize = 8;
    let mut rows: VecDeque<SlowRow> = VecDeque::with_capacity(MAX_ROWS);
    let mut total: u64 = 0;
    let mut tick = interval(Duration::from_secs(args.interval.max(1)));
    let start = std::time::Instant::now();

    while running.load(Ordering::SeqCst) {
        tokio::select! {
            _ = tick.tick() => {
                let lost = total_lost.load(Ordering::Relaxed);
                render_slow_table(&rows, total, lost, args.threshold, start.elapsed());
            }
            ev = rx.recv() => {
                let Some(ev) = ev else { break; };
                total += 1;
                let op = func_id_to_display(ev.func_id);
                let row = SlowRow {
                    ts_clock: format_clock_ns(ev.ts),
                    op: op.to_string(),
                    latency_us: ev.latency_ns as f64 / 1000.0,
                    size: ev.size,
                    note: note_for_op(op),
                };
                if rows.len() == MAX_ROWS {
                    rows.pop_front();
                }
                rows.push_back(row);
            }
        }
    }

    for h in handles {
        h.abort();
    }

    eprintln!("\n  Stopped.");
    Ok(())
}

fn render_slow_table(
    rows: &VecDeque<SlowRow>,
    total: u64,
    lost: u64,
    threshold: u64,
    elapsed: Duration,
) {
    print!("\x1B[2J\x1B[H");

    // Column widths
    const W_TS: usize = 13; // "  02:17:41.023 "
    const W_OP: usize = 10;
    const W_LAT: usize = 9;
    const W_SIZE: usize = 8;
    const W_NOTE: usize = 18;

    // Title row
    let title = format!(" Slow Operations (threshold: {}μs) ", threshold);
    let inside_w = W_TS + W_OP + W_LAT + W_SIZE + W_NOTE + 4 /* separators */ + 10 /* cell padding */;
    let pad = inside_w.saturating_sub(title.chars().count());
    let left = pad / 2;
    let right = pad - left;
    println!(
        "{}",
        format!("╭{}{}{}╮", "─".repeat(left), title, "─".repeat(right)).bright_cyan()
    );

    println!(
        "{}",
        format!(
            "│ {:<w_ts$} │ {:<w_op$} │ {:>w_lat$} │ {:>w_size$} │ {:<w_note$} │",
            "Timestamp",
            "Op",
            "Latency",
            "Size",
            "Note",
            w_ts = W_TS,
            w_op = W_OP,
            w_lat = W_LAT,
            w_size = W_SIZE,
            w_note = W_NOTE,
        )
        .bright_cyan()
    );
    println!(
        "{}",
        format!(
            "├{}┼{}┼{}┼{}┼{}┤",
            "─".repeat(W_TS + 2),
            "─".repeat(W_OP + 2),
            "─".repeat(W_LAT + 2),
            "─".repeat(W_SIZE + 2),
            "─".repeat(W_NOTE + 2),
        )
        .bright_cyan()
    );

    if rows.is_empty() {
        println!(
            "│ {:^width$} │",
            "(waiting for slow events…)".dimmed(),
            width = inside_w - 2
        );
    } else {
        for r in rows {
            println!(
                "│ {:<w_ts$} │ {:<w_op$} │ {:>w_lat$} │ {:>w_size$} │ {:<w_note$} │",
                r.ts_clock,
                r.op,
                format!("{}μs", format_qps(r.latency_us as u64)),
                format_bytes(r.size),
                r.note,
                w_ts = W_TS,
                w_op = W_OP,
                w_lat = W_LAT,
                w_size = W_SIZE,
                w_note = W_NOTE,
            );
        }
    }

    println!(
        "{}",
        format!(
            "╰{}┴{}┴{}┴{}┴{}╯",
            "─".repeat(W_TS + 2),
            "─".repeat(W_OP + 2),
            "─".repeat(W_LAT + 2),
            "─".repeat(W_SIZE + 2),
            "─".repeat(W_NOTE + 2),
        )
        .bright_cyan()
    );

    let window = elapsed.as_secs().min(60);
    println!(
        "  Showing {} of {} slow operations in last {}s.",
        rows.len(),
        total,
        window.max(1),
    );

    // P-3: BPF event loss rate. The denominator is total events the BPF side
    // attempted to emit (delivered + dropped); a healthy run should keep this
    // under 0.1% per the project performance constraints.
    let attempted = total + lost;
    let loss_pct = if attempted > 0 {
        lost as f64 / attempted as f64 * 100.0
    } else {
        0.0
    };
    let label = format!(
        "  BPF event loss: {} / {} attempted  ({:.4}%)",
        lost, attempted, loss_pct
    );
    if loss_pct >= 0.1 {
        println!("{}  ⚠️  exceeds P-3 budget (0.1%)", label.bright_red());
    } else if lost > 0 {
        println!("{}", label.bright_yellow());
    } else {
        println!("{}", label.dimmed());
    }
}

// ════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════

fn detect_ckb_version(binary: &str) -> String {
    let output = Command::new(binary)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default();
    let trimmed = output.trim();
    // CKB prints e.g. "ckb 0.205.0 (a1b2c3d 2025-01-01)"
    if let Some(rest) = trimmed.strip_prefix("ckb ") {
        if let Some(version) = rest.split_whitespace().next() {
            if !version.is_empty() {
                return format!("CKB v{}", version);
            }
        }
    }
    "CKB".to_string()
}

fn func_id_to_display(id: u32) -> &'static str {
    match id {
        1 => "GET",
        2 => "PUT_RAW",
        3 => "DELETE",
        4 => "WRITE",
        5 => "ITER_NEW",
        6 => "MULTI_GET",
        7 => "PUT",
        8 => "TXN_COMMIT",
        _ => "UNKNOWN",
    }
}

fn note_for_op(op: &str) -> &'static str {
    match op {
        "WRITE" => "batch write",
        "TXN_COMMIT" => "txn commit",
        "ITER_NEW" => "iterator open",
        _ => "",
    }
}

fn bucket_label(bucket: usize) -> String {
    let ns = 1u64 << bucket;
    if ns < 1_000 {
        format!("{}ns", ns)
    } else if ns < 1_000_000 {
        format!("{}μs", ns / 1_000)
    } else if ns < 1_000_000_000 {
        format!("{}ms", ns / 1_000_000)
    } else {
        format!("{}s", ns / 1_000_000_000)
    }
}

fn format_duration(d: std::time::Duration) -> String {
    let secs = d.as_secs();
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

/// Render a wall-clock-style hh:mm:ss from elapsed program time.
fn format_clock(d: Duration) -> String {
    let now = Utc::now();
    let _ = d; // wall-clock time is more useful for an alert label
    now.format("%H:%M:%S").to_string()
}

/// Render a high-resolution clock from a kernel timestamp (boot-relative).
/// We don't have a real wall clock here, so we use the bpf_ktime_get_ns
/// value formatted as `MM:SS.mmm` modulo 60 minutes — sufficient to order
/// events visually within a session.
fn format_clock_ns(ts_ns: u64) -> String {
    let total_ms = ts_ns / 1_000_000;
    let mm = (total_ms / 60_000) % 60;
    let ss = (total_ms / 1_000) % 60;
    let ms = total_ms % 1_000;
    format!("{:02}:{:02}.{:03}", mm, ss, ms)
}

/// Format an integer with comma thousands separators.
fn format_qps(qps: u64) -> String {
    let s = qps.to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out.chars().rev().collect()
}

fn format_bytes(bytes: u64) -> String {
    if bytes == 0 {
        return "—".to_string();
    }
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else if bytes < 1024 * 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

fn format_bytes_per_sec(bps: u64) -> String {
    if bps == 0 {
        return "0 B/s".to_string();
    }
    if bps < 1024 {
        format!("{} B/s", bps)
    } else if bps < 1024 * 1024 {
        format!("{:.1} KB/s", bps as f64 / 1024.0)
    } else if bps < 1024 * 1024 * 1024 {
        format!("{:.1} MB/s", bps as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.1} GB/s", bps as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

fn round2(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}
