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

    let buf = fs::read(path).with_context(|| format!("cannot read {}", path.display()))?;

    let elf = match goblin::Object::parse(&buf).with_context(|| "failed to parse ELF")? {
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
            .filter(|s| is_direct_match(&s.demangled, substr))
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

    let tier3_missing_count = tier3_missing.len();

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
            tier3_missing_count,
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
                &format!("{}", "✅ Ideal — C API symbols embedded in binary".green()),
            );
        }
        RocksdbLinkage::Dynamic => {
            kv("Evidence", "librocksdb.so found in dynamic dependencies");
            kv(
                "Assessment",
                &format!("{}", "✅ Symbols available in shared library".green()),
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
            println!("  {}", "⚠️  No Tier 1 symbols found!".red().bold());
        } else {
            for s in &r.tier1 {
                print!("  {} {:<46} ", "✅".green(), s.raw_name,);
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
        if d == 0 {
            0
        } else {
            n * 100 / d
        }
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
// Symbol matching helpers
// ════════════════════════════════════════════════════════════════════

/// Compiler-generated symbol prefixes that should be excluded from Tier 2
/// matching. These are generic instantiations (drop glue, vtable shims, etc.)
/// that happen to contain the target path inside angle brackets.
const NOISE_PREFIXES: &[&str] = &[
    "core::ptr::drop_in_place<",
    "<core::future::from_generator::GenFuture<",
    "core::future::future::Future::poll<",
    "<alloc::boxed::Box<",
    "<core::pin::Pin<",
];

/// Check whether `demangled` is a direct match for `target_path`, not just a
/// substring buried inside compiler-generated generic wrappers.
///
/// A direct match means the symbol's demangled name either:
///   1. Starts with the target path (e.g. `Foo::bar` matches `Foo::bar::{{closure}}`), or
///   2. Contains the target path but NOT inside `<...>` angle brackets (which
///      indicate it's a generic type parameter, not the actual function).
fn is_direct_match(demangled: &str, target_path: &str) -> bool {
    // Fast path: no match at all
    if !demangled.contains(target_path) {
        return false;
    }

    // Reject known compiler-generated prefixes
    for prefix in NOISE_PREFIXES {
        if demangled.starts_with(prefix) {
            return false;
        }
    }

    // Accept if the symbol starts with the target path
    if demangled.starts_with(target_path) {
        return true;
    }

    // Otherwise, check that target_path appears at top-level scope (nesting
    // depth 0), not inside angle brackets. This filters out cases like
    // `Wrapper<Foo::bar>` while accepting `Foo::bar::{{closure}}`.
    let mut depth: i32 = 0;
    // Find all occurrences and check if any is at depth 0
    let target_bytes = target_path.as_bytes();
    let demangled_bytes = demangled.as_bytes();

    for (i, &b) in demangled_bytes.iter().enumerate() {
        match b {
            b'<' => depth += 1,
            b'>' => depth -= 1,
            _ => {}
        }
        if depth == 0
            && i + target_bytes.len() <= demangled_bytes.len()
            && &demangled_bytes[i..i + target_bytes.len()] == target_bytes
        {
            return true;
        }
    }

    false
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
    println!(
        "── {} {}",
        title.bold(),
        "─".repeat(52usize.saturating_sub(title.len()))
    );
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
        let mangled = "_ZN8ckb_sync12synchronizer12Synchronizer8received17h0123456789abcdefE";
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

    #[test]
    fn direct_match_accepts_exact() {
        assert!(is_direct_match(
            "ckb_network::network::NetworkService::start",
            "ckb_network::network::NetworkService::start"
        ));
    }

    #[test]
    fn direct_match_accepts_closure() {
        assert!(is_direct_match(
            "ckb_network::network::NetworkService::start::{{closure}}::{{closure}}",
            "ckb_network::network::NetworkService::start"
        ));
    }

    #[test]
    fn direct_match_rejects_drop_in_place() {
        assert!(!is_direct_match(
            "core::ptr::drop_in_place<ckb_network::network::NetworkService::start<ckb_async_runtime::native::Handle>::{{closure}}>",
            "ckb_network::network::NetworkService::start"
        ));
    }

    #[test]
    fn direct_match_rejects_nested_generic() {
        assert!(!is_direct_match(
            "core::ptr::drop_in_place<tokio::runtime::task::core::Cell<ckb_async_runtime::native::Handle::spawn<ckb_network::network::NetworkService::start<ckb_async_runtime::native::Handle>::{{closure}}>::{{closure}},alloc::sync::Arc<tokio::runtime::scheduler::multi_thread::handle::Handle>>>",
            "ckb_network::network::NetworkService::start"
        ));
    }

    #[test]
    fn direct_match_accepts_with_generic_suffix() {
        // The actual function with its own generic param should still match
        assert!(is_direct_match(
            "ckb_network::network::NetworkService::start<ckb_async_runtime::native::Handle>",
            "ckb_network::network::NetworkService::start"
        ));
    }
}
