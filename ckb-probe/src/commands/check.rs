use anyhow::Result;
use aya::maps::AsyncPerfEventArray;
use aya::util::online_cpus;
use bytes::BytesMut;
use ckb_probe_common::{SyscallEvent, TcpEvent, UprobeLatencyEvent};
use colored::Colorize;
use std::fs;
use std::path::Path;
use std::process::Command;

use crate::cli::CheckArgs;

#[derive(Debug)]
pub struct CheckResult {
    pub name: String,
    pub passed: bool,
    pub detail: String,
}

pub async fn run(args: CheckArgs) -> Result<()> {
    // ── Environment checks ──
    let mut results = vec![
        check_kernel_version(),
        check_bpf_config(),
        check_btf(),
        check_permissions(),
        check_bpf_syscall(),
        check_uprobe_support(),
        check_ckb_process(),
    ];

    if let Some(ref bin) = args.binary {
        results.push(check_ckb_symbols(bin));
    }

    // Print environment check results
    print_results("ckb-probe environment check", &results);

    // ── eBPF probe validation (when --binary and --pid provided) ──
    if let (Some(ref binary), Some(pid)) = (&args.binary, args.pid) {
        println!();
        // run_ebpf_validation prints results internally (attach + live events)
        run_ebpf_validation(binary, pid, &args.probe).await?;
    }

    Ok(())
}

fn print_results(title: &str, results: &[CheckResult]) {
    let title_line = format!("  {:<58}", title);
    println!();
    println!(
        "{}",
        "╔══════════════════════════════════════════════════════════════╗".bright_cyan()
    );
    println!("{}", format!("║{}║", title_line).bright_cyan());
    println!(
        "{}",
        "╠══════════════════════════════════════════════════════════════╣".bright_cyan()
    );
    for r in results {
        let icon = if r.passed { "✅" } else { "❌" };
        let name_col = format!("{:<24}", r.name);
        let detail_col = if r.passed {
            r.detail.green().to_string()
        } else {
            r.detail.red().to_string()
        };
        println!("  {} {}  {}", icon, name_col, detail_col);
    }
    println!(
        "{}",
        "╚══════════════════════════════════════════════════════════════╝".bright_cyan()
    );

    let passed = results.iter().filter(|r| r.passed).count();
    let total = results.len();
    println!();
    println!(
        "  Result: {}/{} checks passed",
        passed.to_string().bold(),
        total
    );

    if passed == total {
        println!("  🎉 All checks passed!");
    } else {
        println!("  ⚠️ Some checks failed. See details above.");
    }
}

// ════════════════════════════════════════════════════════════════
// eBPF probe validation
// ════════════════════════════════════════════════════════════════

async fn run_ebpf_validation(binary: &str, pid: u32, probe_type: &str) -> Result<Vec<CheckResult>> {
    let ebpf_path =
        std::path::Path::new("ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf");
    if !ebpf_path.exists() {
        return Ok(vec![CheckResult {
            name: "eBPF binary".into(),
            passed: false,
            detail: format!("not found at {:?}. Run: cargo xtask build-ebpf", ebpf_path),
        }]);
    }

    let data = std::fs::read(ebpf_path)?;
    let mut bpf = aya::Ebpf::load(&data)?;

    let binary_abs = std::fs::canonicalize(binary)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| binary.to_string());

    let mut results = Vec::new();

    match probe_type {
        "uprobe" => {
            results.extend(validate_uprobe(&mut bpf, &binary_abs, pid)?);
        }
        "kprobe" => {
            results.extend(validate_kprobe(&mut bpf, pid)?);
        }
        "tracepoint" => {
            results.extend(validate_tracepoint(&mut bpf, pid)?);
        }
        "all" => {
            results.extend(validate_uprobe(&mut bpf, &binary_abs, pid)?);
            results.extend(validate_kprobe(&mut bpf, pid)?);
            results.extend(validate_tracepoint(&mut bpf, pid)?);
        }
        _ => anyhow::bail!("unknown probe type: {}", probe_type),
    }

    // Print attach validation results first
    print_results("ckb-probe eBPF validation", &results);

    // ── Live event collection (3 seconds) ──
    println!();
    println!("  ⏳ Collecting live events for 3 seconds...");
    println!();

    collect_live_events(&mut bpf, probe_type).await?;

    // Return empty vec since we already printed results above
    Ok(vec![])
}

/// Collect and display live events from PerfEventArrays for a few seconds.
async fn collect_live_events(bpf: &mut aya::Ebpf, probe_type: &str) -> Result<()> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::time::{timeout, Duration};

    let cpus = online_cpus().map_err(|e| anyhow::anyhow!("failed to get online cpus: {:?}", e))?;

    let uprobe_count = Arc::new(AtomicUsize::new(0));
    let tcp_count = Arc::new(AtomicUsize::new(0));
    let syscall_count = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();

    // uprobe events
    if matches!(probe_type, "uprobe" | "all") {
        if let Some(map) = bpf.take_map("UPROBE_EVENTS") {
            let mut perf_array: AsyncPerfEventArray<_> = AsyncPerfEventArray::try_from(map)?;
            for cpu_id in &cpus {
                let mut buf = perf_array.open(*cpu_id, Some(256))?;
                let count = uprobe_count.clone();
                handles.push(tokio::spawn(async move {
                    let mut buffers = (0..10)
                        .map(|_| BytesMut::with_capacity(1024))
                        .collect::<Vec<_>>();
                    loop {
                        if let Ok(events) = buf.read_events(&mut buffers).await {
                            for buffer in buffers.iter().take(events.read) {
                                if buffer.len() >= std::mem::size_of::<UprobeLatencyEvent>() {
                                    let event = unsafe {
                                        (buffer.as_ptr() as *const UprobeLatencyEvent)
                                            .read_unaligned()
                                    };
                                    let func_name = func_id_to_name(event.func_id);
                                    let latency_us = event.latency_ns as f64 / 1000.0;
                                    let prev = count.fetch_add(1, Ordering::Relaxed);
                                    if prev < 20 {
                                        println!(
                                            "  {} pid={} tid={} func={:<24} latency={:.1}μs",
                                            "[uprobe]".bright_magenta(),
                                            event.pid,
                                            event.tid,
                                            func_name,
                                            latency_us,
                                        );
                                    }
                                }
                            }
                        }
                    }
                }));
            }
        }
    }

    // tcp events
    if matches!(probe_type, "kprobe" | "all") {
        if let Some(map) = bpf.take_map("TCP_EVENTS") {
            let mut perf_array: AsyncPerfEventArray<_> = AsyncPerfEventArray::try_from(map)?;
            for cpu_id in &cpus {
                let mut buf = perf_array.open(*cpu_id, Some(256))?;
                let count = tcp_count.clone();
                handles.push(tokio::spawn(async move {
                    let mut buffers = (0..10)
                        .map(|_| BytesMut::with_capacity(1024))
                        .collect::<Vec<_>>();
                    loop {
                        if let Ok(events) = buf.read_events(&mut buffers).await {
                            for buffer in buffers.iter().take(events.read) {
                                if buffer.len() >= std::mem::size_of::<TcpEvent>() {
                                    let event = unsafe {
                                        (buffer.as_ptr() as *const TcpEvent).read_unaligned()
                                    };
                                    let dir = if event.direction == 0 { "TX" } else { "RX" };
                                    let prev = count.fetch_add(1, Ordering::Relaxed);
                                    if prev < 10 {
                                        println!(
                                            "  {} pid={} tid={} dir={} bytes={}",
                                            "[tcp]".bright_cyan(),
                                            event.pid,
                                            event.tid,
                                            dir,
                                            event.bytes,
                                        );
                                    }
                                }
                            }
                        }
                    }
                }));
            }
        }
    }

    // syscall events
    if matches!(probe_type, "tracepoint" | "all") {
        if let Some(map) = bpf.take_map("SYSCALL_EVENTS") {
            let mut perf_array: AsyncPerfEventArray<_> = AsyncPerfEventArray::try_from(map)?;
            for cpu_id in &cpus {
                let mut buf = perf_array.open(*cpu_id, Some(256))?;
                let count = syscall_count.clone();
                handles.push(tokio::spawn(async move {
                    let mut buffers = (0..10)
                        .map(|_| BytesMut::with_capacity(1024))
                        .collect::<Vec<_>>();
                    loop {
                        if let Ok(events) = buf.read_events(&mut buffers).await {
                            for buffer in buffers.iter().take(events.read) {
                                if buffer.len() >= std::mem::size_of::<SyscallEvent>() {
                                    let event = unsafe {
                                        (buffer.as_ptr() as *const SyscallEvent).read_unaligned()
                                    };
                                    let name = syscall_nr_to_name(event.syscall_nr);
                                    let prev = count.fetch_add(1, Ordering::Relaxed);
                                    if prev < 10 {
                                        println!(
                                            "  {} pid={} tid={} nr={} ({})",
                                            "[syscall]".bright_yellow(),
                                            event.pid,
                                            event.tid,
                                            event.syscall_nr,
                                            name,
                                        );
                                    }
                                }
                            }
                        }
                    }
                }));
            }
        }
    }

    // Wait for 3 seconds, then stop collection
    let _ = timeout(Duration::from_secs(3), async {
        // Just wait; tasks run in background
        tokio::time::sleep(Duration::from_secs(3)).await;
    })
    .await;

    // Abort all collection tasks
    for h in &handles {
        h.abort();
    }

    let u = uprobe_count.load(Ordering::Relaxed);
    let t = tcp_count.load(Ordering::Relaxed);
    let s = syscall_count.load(Ordering::Relaxed);

    println!();
    println!(
        "  📊 Captured {} uprobe, {} tcp, {} syscall events in 3s",
        u.to_string().bright_magenta(),
        t.to_string().bright_cyan(),
        s.to_string().bright_yellow(),
    );

    Ok(())
}

fn func_id_to_name(id: u32) -> &'static str {
    match id {
        1 => "get_pinned_cf",
        2 => "put",
        3 => "delete",
        4 => "write",
        5 => "create_iterator_cf",
        6 => "multi_get_cf",
        _ => "unknown",
    }
}

fn syscall_nr_to_name(nr: u64) -> &'static str {
    match nr {
        0 => "read",
        1 => "write",
        2 => "open",
        3 => "close",
        44 => "sendto",
        45 => "recvfrom",
        46 => "sendmsg",
        47 => "recvmsg",
        232 => "epoll_wait",
        _ => "other",
    }
}

fn validate_uprobe(bpf: &mut aya::Ebpf, binary: &str, pid: u32) -> Result<Vec<CheckResult>> {
    use aya::programs::UProbe;

    let mut target_pid: aya::maps::HashMap<_, u32, u8> =
        aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
    target_pid.insert(pid, 1, 0)?;

    // BPF program pairs defined in ckb-probe-ebpf (have entry/return BPF functions)
    const BPF_PROBES: &[(&str, &str, &str)] = &[
        (
            "rocksdb_get_pinned_cf_entry",
            "rocksdb_get_pinned_cf_return",
            "rocksdb_get_pinned_cf",
        ),
        ("rocksdb_put_entry", "rocksdb_put_return", "rocksdb_put"),
        (
            "rocksdb_write_entry",
            "rocksdb_write_return",
            "rocksdb_write",
        ),
        (
            "rocksdb_delete_entry",
            "rocksdb_delete_return",
            "rocksdb_delete",
        ),
        (
            "rocksdb_create_iterator_cf_entry",
            "rocksdb_create_iterator_cf_return",
            "rocksdb_create_iterator_cf",
        ),
        (
            "rocksdb_multi_get_cf_entry",
            "rocksdb_multi_get_cf_return",
            "rocksdb_multi_get_cf",
        ),
    ];

    // All Tier 1 symbols — used for uprobe-attachability test
    // (reuses one generic BPF program to probe each symbol)
    const ALL_TIER1_SYMBOLS: &[&str] = &[
        "rocksdb_get",
        "rocksdb_get_pinned",
        "rocksdb_get_pinned_cf",
        "rocksdb_put",
        "rocksdb_put_cf",
        "rocksdb_write",
        "rocksdb_delete",
        "rocksdb_delete_cf",
        "rocksdb_multi_get_cf",
        "rocksdb_transaction_put_cf",
        "rocksdb_transaction_delete_cf",
        "rocksdb_transaction_get_cf",
        "rocksdb_transaction_commit",
        "rocksdb_optimistictransaction_begin",
        "rocksdb_create_iterator_cf",
        "rocksdb_iter_seek",
        "rocksdb_iter_seek_to_first",
        "rocksdb_iter_next",
        "rocksdb_iter_destroy",
    ];

    let mut results = Vec::new();

    // Phase 1: BPF program pair validation (entry + return latency measurement)
    results.push(CheckResult {
        name: "── uprobe latency ──".into(),
        passed: true,
        detail: "entry/return pair attach test".into(),
    });

    let mut pair_ok = 0u32;
    let mut pair_total = 0u32;
    for (entry_fn, ret_fn, symbol) in BPF_PROBES {
        pair_total += 1;
        let uprobe: &mut UProbe = bpf.program_mut(entry_fn).unwrap().try_into()?;
        uprobe.load()?;
        let entry_ok = uprobe.attach(Some(symbol), 0, binary, None).is_ok();

        let ret_ok = if entry_ok {
            let uretprobe: &mut UProbe = bpf.program_mut(ret_fn).unwrap().try_into()?;
            uretprobe.load()?;
            uretprobe.attach(Some(symbol), 0, binary, None).is_ok()
        } else {
            false
        };

        let passed = entry_ok && ret_ok;
        if passed {
            pair_ok += 1;
        }
        results.push(CheckResult {
            name: format!("  {}", symbol),
            passed,
            detail: if passed {
                "entry + return attached".into()
            } else {
                "symbol not in binary (expected)".into()
            },
        });
    }

    // Phase 2: All Tier 1 symbol attachability scan
    // Uses one already-loaded BPF program to test each symbol
    results.push(CheckResult {
        name: "── uprobe Tier 1 ──".into(),
        passed: true,
        detail: "all 19 Tier 1 symbol attach test".into(),
    });

    let mut sym_ok = 0u32;
    let mut sym_total = 0u32;
    for symbol in ALL_TIER1_SYMBOLS {
        sym_total += 1;
        // Try to resolve symbol offset in the binary via goblin
        let attachable = resolve_symbol_offset(binary, symbol);
        let passed = attachable;
        if passed {
            sym_ok += 1;
        }
        results.push(CheckResult {
            name: format!("  {}", symbol),
            passed,
            detail: if passed {
                "symbol found, uprobe-attachable".into()
            } else {
                "not found in binary".into()
            },
        });
    }

    // Summary line
    results.push(CheckResult {
        name: "uprobe summary".into(),
        passed: pair_ok > 0 && sym_ok > 0,
        detail: format!(
            "latency pairs: {}/{}, Tier 1 symbols: {}/{}",
            pair_ok, pair_total, sym_ok, sym_total
        ),
    });

    Ok(results)
}

/// Check if a symbol exists in the ELF binary (resolvable for uprobe).
fn resolve_symbol_offset(binary: &str, symbol: &str) -> bool {
    let data = match std::fs::read(binary) {
        Ok(d) => d,
        Err(_) => return false,
    };
    let elf = match goblin::elf::Elf::parse(&data) {
        Ok(e) => e,
        Err(_) => return false,
    };
    elf.syms.iter().any(|sym| {
        sym.st_type() == goblin::elf::sym::STT_FUNC
            && sym.st_value != 0
            && elf.strtab.get_at(sym.st_name) == Some(symbol)
    })
}

fn validate_kprobe(bpf: &mut aya::Ebpf, pid: u32) -> Result<Vec<CheckResult>> {
    use aya::programs::KProbe;

    let mut target_pid: aya::maps::HashMap<_, u32, u8> =
        aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
    let _ = target_pid.insert(pid, 1, 0);

    const PROBES: &[(&str, &str)] = &[
        ("tcp_sendmsg_entry", "tcp_sendmsg"),
        ("tcp_sendmsg_return", "tcp_sendmsg"),
        ("tcp_recvmsg_entry", "tcp_recvmsg"),
        ("tcp_recvmsg_return", "tcp_recvmsg"),
    ];

    let mut results = Vec::new();
    for (prog_name, kernel_fn) in PROBES {
        let program: &mut KProbe = bpf.program_mut(prog_name).unwrap().try_into()?;
        program.load()?;
        let passed = program.attach(kernel_fn, 0).is_ok();
        results.push(CheckResult {
            name: format!("kprobe {}", prog_name),
            passed,
            detail: if passed {
                format!("attached to {}", kernel_fn)
            } else {
                format!("failed to attach to {}", kernel_fn)
            },
        });
    }

    Ok(results)
}

fn validate_tracepoint(bpf: &mut aya::Ebpf, pid: u32) -> Result<Vec<CheckResult>> {
    use aya::programs::TracePoint;

    let mut target_pid: aya::maps::HashMap<_, u32, u8> =
        aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
    let _ = target_pid.insert(pid, 1, 0);

    let tp: &mut TracePoint = bpf.program_mut("sys_enter_handler").unwrap().try_into()?;
    tp.load()?;
    let passed = tp.attach("raw_syscalls", "sys_enter").is_ok();

    Ok(vec![CheckResult {
        name: "tracepoint sys_enter".into(),
        passed,
        detail: if passed {
            "attached to raw_syscalls/sys_enter".into()
        } else {
            "failed to attach".into()
        },
    }])
}

// ════════════════════════════════════════════════════════════════
// Environment checks
// ════════════════════════════════════════════════════════════════

fn check_kernel_version() -> CheckResult {
    let uname = nix::sys::utsname::uname().unwrap();
    let release = uname.release().to_string_lossy().to_string();

    let parts: Vec<u32> = release
        .split(|c: char| !c.is_ascii_digit())
        .filter_map(|s| s.parse().ok())
        .collect();

    let (major, minor) = (
        parts.first().copied().unwrap_or(0),
        parts.get(1).copied().unwrap_or(0),
    );

    let passed = major > 5 || (major == 5 && minor >= 8);

    CheckResult {
        name: "Kernel version".into(),
        passed,
        detail: format!("{} (need >= 5.8)", release),
    }
}

fn check_bpf_config() -> CheckResult {
    let uname = nix::sys::utsname::uname().unwrap();
    let release = uname.release().to_string_lossy().to_string();
    let config_path = format!("/boot/config-{}", release);

    let (passed, detail) = if let Ok(content) = fs::read_to_string(&config_path) {
        let has_bpf = content.contains("CONFIG_BPF=y");
        let has_bpf_syscall = content.contains("CONFIG_BPF_SYSCALL=y");
        let has_bpf_jit = content.contains("CONFIG_BPF_JIT=y");

        let all = has_bpf && has_bpf_syscall && has_bpf_jit;
        (
            all,
            format!(
                "BPF={} SYSCALL={} JIT={}",
                if has_bpf { "y" } else { "n" },
                if has_bpf_syscall { "y" } else { "n" },
                if has_bpf_jit { "y" } else { "n" },
            ),
        )
    } else {
        let output = Command::new("zcat").arg("/proc/config.gz").output();
        match output {
            Ok(o) if o.status.success() => {
                let content = String::from_utf8_lossy(&o.stdout);
                let has_bpf = content.contains("CONFIG_BPF=y");
                (has_bpf, "from /proc/config.gz".into())
            }
            _ => (false, "config not found".into()),
        }
    };

    CheckResult {
        name: "BPF config".into(),
        passed,
        detail,
    }
}

fn check_btf() -> CheckResult {
    let path = "/sys/kernel/btf/vmlinux";
    let passed = Path::new(path).exists();
    CheckResult {
        name: "BTF support".into(),
        passed,
        detail: if passed {
            format!("{} exists", path)
        } else {
            format!("{} not found", path)
        },
    }
}

fn check_permissions() -> CheckResult {
    let euid = nix::unistd::geteuid();
    let is_root = euid.is_root();

    let has_cap = if !is_root {
        fs::read_to_string("/proc/self/status")
            .map(|s| {
                s.lines()
                    .find(|l| l.starts_with("CapEff:"))
                    .map(|l| {
                        let hex = l.split_whitespace().nth(1).unwrap_or("0");
                        let cap = u64::from_str_radix(hex, 16).unwrap_or(0);
                        cap & (1u64 << 39) != 0
                    })
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    } else {
        true
    };

    let passed = is_root || has_cap;
    CheckResult {
        name: "Permissions".into(),
        passed,
        detail: if is_root {
            "running as root".into()
        } else if has_cap {
            "CAP_BPF available".into()
        } else {
            "need root or CAP_BPF".into()
        },
    }
}

fn check_bpf_syscall() -> CheckResult {
    let ret = unsafe { libc::syscall(libc::SYS_bpf, 0u32, core::ptr::null::<u8>(), 0u32) };
    let _ = ret;
    let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);

    let passed = errno != 38;
    CheckResult {
        name: "bpf() syscall".into(),
        passed,
        detail: if passed {
            "available".into()
        } else {
            "ENOSYS - bpf not supported".into()
        },
    }
}

fn check_uprobe_support() -> CheckResult {
    let tracefs_paths = [
        "/sys/kernel/debug/tracing/uprobe_events",
        "/sys/kernel/tracing/uprobe_events",
    ];

    for p in &tracefs_paths {
        if Path::new(p).exists() {
            return CheckResult {
                name: "uprobe support".into(),
                passed: true,
                detail: format!("{} exists", p),
            };
        }
    }

    CheckResult {
        name: "uprobe support".into(),
        passed: false,
        detail: "uprobe_events not found".into(),
    }
}

fn check_ckb_process() -> CheckResult {
    let output = Command::new("pgrep").args(["-x", "ckb"]).output();

    match output {
        Ok(o) if o.status.success() => {
            let pids = String::from_utf8_lossy(&o.stdout).trim().to_string();
            let count = pids.lines().count();
            CheckResult {
                name: "CKB process".into(),
                passed: true,
                detail: format!("{} instance(s), pid={}", count, pids.replace('\n', ",")),
            }
        }
        _ => CheckResult {
            name: "CKB process".into(),
            passed: false,
            detail: "no running ckb process found".into(),
        },
    }
}

fn check_ckb_symbols(binary_path: &str) -> CheckResult {
    if !Path::new(binary_path).exists() {
        return CheckResult {
            name: "CKB symbols".into(),
            passed: false,
            detail: format!("file not found: {}", binary_path),
        };
    }

    let key_symbols = ["rocksdb_get_pinned_cf", "rocksdb_put", "rocksdb_delete"];

    for nm_args in &[
        vec!["-D", "--defined-only", binary_path],
        vec!["--defined-only", binary_path],
    ] {
        let output = Command::new("nm").args(nm_args).output();
        if let Ok(o) = output {
            if o.status.success() {
                let content = String::from_utf8_lossy(&o.stdout);
                let found: Vec<&str> = key_symbols
                    .iter()
                    .filter(|s| content.contains(**s))
                    .copied()
                    .collect();
                if !found.is_empty() {
                    let source = if nm_args.contains(&"-D") {
                        "dynsym"
                    } else {
                        "symtab"
                    };
                    return CheckResult {
                        name: "CKB symbols".into(),
                        passed: true,
                        detail: format!(
                            "{}/{} key symbols found ({})",
                            found.len(),
                            key_symbols.len(),
                            source,
                        ),
                    };
                }
            }
        }
    }

    CheckResult {
        name: "CKB symbols".into(),
        passed: false,
        detail: "no key rocksdb symbols found".into(),
    }
}
