# ckb-probe 技术实现详解

> 本文档面向开发者，详细阐述 ckb-probe 的架构设计、核心算法、数据流和每个模块的实现细节。

---

## 一、项目总览

ckb-probe 是一个基于 eBPF 的 CKB 全节点深度可观测性工具。它通过 uprobe、kprobe、tracepoint 三种 BPF 程序类型，在**不修改 CKB 源码**的前提下，对运行中的 CKB 节点进行应用语义级的实时性能追踪。

### 1.1 技术栈

| 层级 | 技术选型 | 说明 |
|------|---------|------|
| 内核态 BPF 程序 | Rust + aya-ebpf 0.1 | `#![no_std]`，编译到 `bpfel-unknown-none` 目标 |
| 用户态控制程序 | Rust + aya 0.13 + tokio | 异步事件消费 + 定时 Map 轮询 |
| ELF 符号解析 | goblin 0.9 + rustc-demangle | 纯 Rust 实现，无需 binutils |
| CLI 框架 | clap 4 (derive) | 子命令：check / symbols / rocksdb |
| 序列化 | serde + serde_json | JSON 报告输出 |
| 构建系统 | cargo workspace + xtask | eBPF 双目标编译管理 |

### 1.2 项目结构

```
ckb-probe/                          ~4,187 行 Rust 代码
├── Cargo.toml                      workspace 根配置
├── .cargo/config.toml              cargo xtask 别名
│
├── ckb-probe-common/               共享类型库 (567 行)
│   ├── Cargo.toml                  feature gate: user(std) / no_std(ebpf)
│   └── src/lib.rs                  eBPF 事件结构体 + 符号注册表
│
├── ckb-probe-ebpf/                 eBPF 内核态程序 (458 行)
│   ├── Cargo.toml                  target = bpfel-unknown-none
│   └── src/main.rs                 uprobe/kprobe/tracepoint BPF 程序
│
├── ckb-probe/                      用户态 CLI (3,115 行)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                 tokio 异步入口 (28 行)
│       ├── cli.rs                  clap 命令行定义 (188 行)
│       └── commands/
│           ├── mod.rs              模块声明 (3 行)
│           ├── check.rs            环境检测 + eBPF 验证 (776 行)
│           ├── symbols.rs          ELF 符号分析引擎 (860 行)
│           └── rocksdb.rs          RocksDB 实时监控 (1,260 行)
│
└── xtask/                          构建辅助 (47 行)
    └── src/main.rs                 cargo xtask build-ebpf / build
```

### 1.3 关键设计决策

**为什么选择 Aya 框架？**

aya 实现了纯 Rust 全栈 eBPF 开发——内核态和用户态代码使用同一语言。事件类型通过 `ckb-probe-common` crate 直接共享，消除了 C/Rust 边界的序列化开销和类型不一致风险。无需安装 clang/llvm/libelf。

**为什么 RocksDB C API 是首选探测目标？**

CKB 通过 `librocksdb-sys` crate 从源码编译 RocksDB 并静态链接。RocksDB 的 C API 函数（如 `rocksdb_get_pinned_cf`）以 `extern "C"` 声明，不受 Rust name mangling 和 LTO 内联的影响，跨所有 CKB 版本符号名不变——是 uprobe 的理想目标。

---

## 二、ckb-probe-common：共享类型库

### 2.1 条件编译架构

```rust
#![cfg_attr(not(feature = "user"), no_std)]
```

`ckb-probe-common` 同时服务两个编译目标：

| 目标 | feature | std | 可用类型 |
|------|---------|-----|---------|
| eBPF 内核态 (`bpfel-unknown-none`) | 无 (default-features = false) | `no_std` | 事件结构体 + 枚举 + 常量 |
| 用户态 (`x86_64-unknown-linux-gnu`) | `user` | std | 上述 + serde 序列化 + aya::Pod + 符号注册表 |

这种设计确保内核态/用户态之间共享**完全相同的内存布局**，消除了手动 FFI 定义的风险。

### 2.2 eBPF 共享事件结构体

所有结构体均标注 `#[repr(C)]` 以确保确定性的内存布局：

```rust
/// uprobe 延迟事件 — 28 字节
#[repr(C)]
#[derive(Clone, Copy)]
pub struct UprobeLatencyEvent {
    pub pid: u32,         // 进程 ID
    pub tid: u32,         // 线程 ID（用于 entry/return 配对）
    pub func_id: u32,     // RocksDbFunc 枚举值，区分不同操作
    pub latency_ns: u64,  // 函数执行耗时（纳秒）
    pub ts: u64,          // 内核单调时钟时间戳
}
```

`func_id` 使用 `RocksDbFunc` 枚举编码，支持 8 种 RocksDB 操作：

```rust
#[repr(u32)]
pub enum RocksDbFunc {
    GetPinnedCf = 1,       // CKB 主读路径
    Put = 2,               // 通用写入
    Delete = 3,            // 删除
    Write = 4,             // WriteBatch 原子提交
    NewIteratorCf = 5,     // 创建迭代器
    MultiGetCf = 6,        // 批量读取
    TransactionPutCf = 7,  // CKB 主写路径（事务写入）
    TransactionCommit = 8, // 事务提交
}
```

### 2.3 监控聚合类型

```rust
/// PerCpuArray 中的聚合统计，每个 CPU 独立维护一份
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct OpStats {
    pub count: u64,       // 调用次数
    pub total_ns: u64,    // 累计延迟（纳秒）
    pub min_ns: u64,      // 最小延迟
    pub max_ns: u64,      // 最大延迟
    pub bytes_total: u64, // 累计数据量（未追踪的为 0）
}

// 用户态需要通过 aya::Pod trait 才能从 PerCpuArray 读取
#[cfg(feature = "user")]
unsafe impl aya::Pod for OpStats {}
```

`aya::Pod` 是一个 unsafe marker trait，声明该类型可以安全地从原始字节反序列化。`OpStats` 的 `#[repr(C)]` 布局保证了这一点。

### 2.4 符号分级注册表

`ProbeTargets` 提供了 53 个预注册的探测目标：

- **Tier 1**（20 个）：RocksDB C API 符号，`extern "C"` 声明，跨版本稳定
- **Tier 2**（21 个）：Rust 跨 crate 公开函数，mangled 名含 hash 后缀
- **Tier 3**（12 个）：crate 内部函数，release 构建中通常被内联消除

注册表的核心用途：`symbols` 子命令遍历注册表，对照 ELF `.symtab` 中的实际符号，生成覆盖率报告。

---

## 三、ckb-probe-ebpf：内核态 BPF 程序

### 3.1 编译与构建

eBPF 程序编译为 `bpfel-unknown-none` 目标（BPF 小端字节序），使用 Rust nightly 的 `-Z build-std=core` 交叉编译 core 库：

```bash
cargo +nightly build --target=bpfel-unknown-none -Z build-std=core --release
```

`xtask/src/main.rs` 封装了这个流程：

```rust
fn build_ebpf() {
    let status = Command::new("cargo")
        .current_dir(std::env::current_dir().unwrap().join("ckb-probe-ebpf"))
        .args(["+nightly", "build", "--target=bpfel-unknown-none",
               "-Z", "build-std=core", "--release"])
        .status()
        .expect("failed to build eBPF program");
    assert!(status.success(), "eBPF build failed");
}
```

编译产物是一个 BPF ELF 文件，位于 `ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf`。用户态程序在运行时通过 `aya::Ebpf::load()` 将其加载到内核。

`Cargo.toml` 中的关键配置：

```toml
[profile.release]
lto = true      # 链接时优化，减小 BPF 程序体积
panic = "abort"  # no_std 环境无法 unwind

[profile.dev]
opt-level = 2    # 即使 dev 构建也启用优化，否则 verifier 可能拒绝
```

### 3.2 BPF Map 架构

BPF Maps 是内核态程序与用户态程序之间的数据交换通道。ckb-probe 使用 11 个 Map：

#### 配置与过滤

| Map | 类型 | 容量 | 数据流 | 用途 |
|-----|------|------|--------|------|
| `TARGET_PID` | HashMap<u32, u8> | 8 | 用户态→内核态 | PID 过滤白名单 |
| `SLOW_THRESHOLD` | Array<u64> | 1 | 用户态→内核态 | 慢操作阈值（纳秒） |

#### 延迟测量（entry/return 配对）

| Map | 类型 | 容量 | 数据流 | 用途 |
|-----|------|------|--------|------|
| `UPROBE_START` | HashMap<u32, (u64, u32, u64)> | 1024 | 内核态内部 | tid → (时间戳, func_id, size) |
| `UPROBE_EVENTS` | PerfEventArray<UprobeLatencyEvent> | — | 内核态→用户态 | 逐事件延迟输出（check 用） |

#### 聚合统计（内核态计算，用户态读取）

| Map | 类型 | 容量 | 数据流 | 用途 |
|-----|------|------|--------|------|
| `OP_STATS` | PerCpuArray<OpStats> | 9 | 内核态写/用户态读 | 每操作统计聚合 |
| `LATENCY_HIST` | PerCpuArray<u64> | 576 | 内核态写/用户态读 | log2 延迟直方图 |
| `SLOW_EVENTS` | RingBuf | 256KB | 内核态→用户态 | 超阈值慢操作事件（批量消费，无逐事件唤醒） |

#### 网络与系统调用

| Map | 类型 | 容量 | 数据流 | 用途 |
|-----|------|------|--------|------|
| `TCP_START` | HashMap<u32, u64> | 1024 | 内核态内部 | kprobe entry 时间戳 |
| `TCP_EVENTS` | PerfEventArray<TcpEvent> | — | 内核态→用户态 | TCP 收发事件 |
| `SYSCALL_EVENTS` | PerfEventArray<SyscallEvent> | — | 内核态→用户态 | syscall 事件 |

**为什么用 PerCpuArray 而非 HashMap？**

PerCpuArray 为每个 CPU 维护独立的数据副本，BPF 程序在更新时无需原子操作或锁。用户态读取时合并所有 CPU 的值。这避免了多 CPU 并发写入同一 Map entry 时的竞争条件。

### 3.3 PID 过滤机制

每个 BPF 程序入口首先检查当前进程是否为目标 CKB 进程：

```rust
#[inline(always)]
fn is_target_pid() -> bool {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    unsafe { TARGET_PID.get(&pid).is_some() }
}
```

`bpf_get_current_pid_tgid()` 返回一个 64 位值：高 32 位是 tgid（即 PID），低 32 位是 tid（即线程 ID）。使用 HashMap lookup 判断是否在白名单中——未命中的进程立即返回，开销约 50ns。

### 3.4 uprobe 延迟测量：entry/return 配对

这是整个项目的核心算法。每个 RocksDB 函数需要一对 BPF 程序：

**Entry（函数入口触发）：**

```rust
#[inline(always)]
fn uprobe_entry(func_id: u32) {
    if !is_target_pid() { return; }
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };          // 纳秒级单调时钟
    let _ = UPROBE_START.insert(&tid, &(ts, func_id), 0);  // 以 tid 为 key 存储
}
```

**Return（函数返回触发）：**

```rust
#[inline(always)]
fn uprobe_return(ctx: &RetProbeContext) {
    let (pid, tid) = current_pid_tid();
    if let Some(&(start_ts, func_id)) = unsafe { UPROBE_START.get(&tid) } {
        let now = unsafe { bpf_ktime_get_ns() };
        let latency_ns = now.saturating_sub(start_ts);

        // 1) 逐事件输出（供 check 命令的实时采集使用）
        UPROBE_EVENTS.output(ctx, &event, 0);

        // 2) 聚合到 OP_STATS（PerCpuArray，无竞争）
        if let Some(stats) = OP_STATS.get_ptr_mut(func_id) {
            (*stats).count += 1;
            (*stats).total_ns += latency_ns;
            // min/max 更新...
        }

        // 3) 更新延迟直方图
        let bucket = log2_u64(latency_ns);
        let hist_idx = func_id * HIST_BUCKETS + bucket;
        if let Some(count) = LATENCY_HIST.get_ptr_mut(hist_idx) {
            *count += 1;
        }

        // 4) 超阈值 → 发送慢操作事件
        if let Some(threshold) = SLOW_THRESHOLD.get(0) {
            if *threshold > 0 && latency_ns > *threshold {
                SLOW_EVENTS.output(ctx, &slow, 0);
            }
        }

        let _ = UPROBE_START.remove(&tid);  // 清理，防止 Map 泄漏
    }
}
```

**为什么用 tid 做 key？** 同一个 RocksDB 函数可能在 CKB 的不同线程中并发执行。tid 是线程唯一的，保证每次调用都能正确配对自己的 entry 和 return。

**数据流图：**

```
CKB 线程 A                          CKB 线程 B
    │                                    │
    ├─ call rocksdb_get_pinned_cf()      ├─ call rocksdb_write()
    │  ┌─ uprobe 触发                    │  ┌─ uprobe 触发
    │  │  UPROBE_START[tidA] = (ts, 1)   │  │  UPROBE_START[tidB] = (ts, 4)
    │  │  ... 函数执行 ...               │  │  ... 函数执行 ...
    │  └─ uretprobe 触发                 │  └─ uretprobe 触发
    │     latency = now - ts             │     latency = now - ts
    │     OP_STATS[1].count++            │     OP_STATS[4].count++
    │     LATENCY_HIST[1*64+bucket]++    │     LATENCY_HIST[4*64+bucket]++
    │     delete UPROBE_START[tidA]      │     delete UPROBE_START[tidB]
```

### 3.5 Verifier-safe log2 实现

BPF verifier 禁止任何可能无限循环的代码。标准的 `while (v >>= 1) r++` 循环会被拒绝。ckb-probe 使用二分查找实现完全展开的 log2：

```rust
#[inline(always)]
fn log2_u64(v: u64) -> u32 {
    if v == 0 { return 0; }
    let mut r = 0u32;
    let mut v = v;
    if v >= 1u64 << 32 { v >>= 32; r += 32; }  // 检查高 32 位
    if v >= 1u64 << 16 { v >>= 16; r += 16; }  // 检查高 16 位
    if v >= 1u64 << 8  { v >>= 8;  r += 8;  }  // 检查高 8 位
    if v >= 1u64 << 4  { v >>= 4;  r += 4;  }  // 检查高 4 位
    if v >= 1u64 << 2  { v >>= 2;  r += 2;  }  // 检查高 2 位
    if v >= 1u64 << 1  { r += 1; }              // 最后 1 位
    r
}
```

6 次比较和移位，编译为 ~18 条 BPF 指令，verifier 可以静态证明其终止性。输出范围 0-63，正好对应 64 个直方图桶。

**直方图桶含义：** 桶 i 覆盖延迟范围 [2^i, 2^(i+1)) 纳秒。例如：
- 桶 10 = [1024, 2048) ns ≈ 1-2 μs
- 桶 20 = [1048576, 2097152) ns ≈ 1-2 ms
- 桶 30 = [1073741824, 2147483648) ns ≈ 1-2 s

### 3.6 BPF 程序清单

| 程序名 | 类型 | 挂载目标 | func_id |
|--------|------|---------|---------|
| `rocksdb_get_pinned_cf_entry/return` | uprobe/uretprobe | `rocksdb_get_pinned_cf` | 1 |
| `rocksdb_put_entry/return` | uprobe/uretprobe | `rocksdb_put` | 2 |
| `rocksdb_delete_entry/return` | uprobe/uretprobe | `rocksdb_delete` | 3 |
| `rocksdb_write_entry/return` | uprobe/uretprobe | `rocksdb_write` | 4 |
| `rocksdb_create_iterator_cf_entry/return` | uprobe/uretprobe | `rocksdb_create_iterator_cf` | 5 |
| `rocksdb_multi_get_cf_entry/return` | uprobe/uretprobe | `rocksdb_multi_get_cf` | 6 |
| `rocksdb_transaction_put_cf_entry/return` | uprobe/uretprobe | `rocksdb_transaction_put_cf` | 7 |
| `rocksdb_transaction_commit_entry/return` | uprobe/uretprobe | `rocksdb_transaction_commit` | 8 |
| `tcp_sendmsg_entry/return` | kprobe/kretprobe | `tcp_sendmsg` | — |
| `tcp_recvmsg_entry/return` | kprobe/kretprobe | `tcp_recvmsg` | — |
| `sys_enter_handler` | tracepoint | `raw_syscalls/sys_enter` | — |

共 8 对 uprobe（16 个 BPF 程序）+ 2 对 kprobe（4 个）+ 1 个 tracepoint = **21 个 BPF 程序**。

### 3.7 syscall 过滤

tracepoint 挂载到 `raw_syscalls/sys_enter`，仅捕获 9 类与 CKB 相关的系统调用：

```rust
let syscall_nr: u64 = unsafe { ctx.read_at(8).unwrap_or(0) };
match syscall_nr {
    0 | 1 | 2 | 3 | 44 | 45 | 46 | 47 | 232 => {}  // 感兴趣的 syscall
    _ => return 0,  // 其他全部丢弃
}
```

`ctx.read_at(8)` 从 tracepoint 上下文的偏移 8 处读取 syscall 编号。这个偏移来自内核的 tracepoint format（`/sys/kernel/debug/tracing/events/raw_syscalls/sys_enter/format`）。

---

## 四、ckb-probe symbols：ELF 符号分析引擎

### 4.1 分析流水线

`commands/symbols.rs` 中 `build_report()` 函数的 9 步分析管线：

```
ELF 二进制 → goblin 解析 → 元数据提取 → 动态依赖 → RocksDB 链接检测
                                                          ↓
         JSON/终端输出 ← 报告汇总 ← Tier 3 追踪 ← Tier 2 匹配 ← Tier 1 匹配 ← demangled 查找表
```

| 步骤 | 操作 | 输出 |
|------|------|------|
| 1 | 读取 ELF class、架构 | `ElfOverview` |
| 2 | 统计 `.symtab` / `.dynsym` 符号数，检测 DWARF 和 strip 状态 | strip_status |
| 3 | 枚举动态依赖（`DT_NEEDED`） | `dynamic_deps` |
| 4 | RocksDB 链接方式检测 | `RocksdbLinkage` |
| 5 | 构建 demangled 查找表 | `HashMap<String, Vec<ResolvedSym>>` |
| 6 | Tier 1 精确匹配 | `tier1: Vec<SymbolInfo>` |
| 7 | Tier 2 子串匹配（含噪声过滤） | `tier2: Vec<SymbolInfo>` |
| 8 | Tier 3 追踪缺失 | `tier3_missing` |
| 9 | 汇总 + 建议 | `ReportSummary` |

### 4.2 RocksDB 链接方式判定

```rust
let rocksdb_linkage = if rocksdb_in_dynlibs || rocksdb_in_dynsym {
    RocksdbLinkage::Dynamic    // DT_NEEDED 或 .dynsym 中有 rocksdb
} else if total_rocksdb_c_symbols > 0 {
    RocksdbLinkage::Static     // .symtab 中有 rocksdb_* 函数但不在动态表
} else {
    RocksdbLinkage::Unknown    // 完全无 rocksdb 符号
};
```

CKB 的判定结果始终是 **Static**：`.symtab` 中有 155 个 `rocksdb_*` 函数符号，但 `DT_NEEDED` 中没有 `librocksdb.so`。

### 4.3 Tier 2 噪声过滤：`is_direct_match()`

Rust 二进制中大量编译器生成的泛型实例化（drop glue、Future poll、Box wrapper）会将目标函数路径嵌入 `<>` 泛型参数中：

```
core::ptr::drop_in_place<tokio::..::Cell<NetworkService::start<Handle>>>
```

简单的 `contains()` 子串匹配会产生大量误报。`is_direct_match()` 通过**角括号深度追踪**解决：

```rust
fn is_direct_match(demangled: &str, target_path: &str) -> bool {
    // 1. 前缀黑名单：排除 core::ptr::drop_in_place<、GenFuture< 等
    // 2. 遍历字符串，维护 <> 嵌套深度
    // 3. 仅接受深度 0（顶层作用域）处的匹配
    // 4. 闭包后缀 ::{{closure}} 仍视为有效匹配
}
```

---

## 五、ckb-probe check：环境检测 + eBPF 验证

### 5.1 8 项环境检测

| # | 检测项 | 实现方式 | 判定标准 |
|---|--------|---------|---------|
| 1 | Kernel version | `nix::sys::utsname::uname()` 解析 major.minor | >= 5.8 |
| 2 | BPF config | 解析 `/boot/config-$(uname -r)` | CONFIG_BPF=y + BPF_SYSCALL=y + BPF_JIT=y |
| 3 | BTF support | 检查文件存在 | `/sys/kernel/btf/vmlinux` 存在 |
| 4 | Permissions | `geteuid()` + 检查 `CapEff` 位 39 | root 或 CAP_BPF |
| 5 | bpf() syscall | `libc::syscall(SYS_bpf, 0, null, 0)` | errno != ENOSYS(38) |
| 6 | uprobe support | 检查 tracefs 路径 | `uprobe_events` 文件存在 |
| 7 | CKB process | `pgrep -x ckb` | 找到运行中的进程 |
| 8 | CKB symbols | `nm` 检查 3 个关键符号 | 至少 1 个 rocksdb_* 存在 |

### 5.2 eBPF 探针验证流程

当同时提供 `--binary` 和 `--pid` 时，执行实际挂载测试：

1. 加载 BPF ELF 到内核（`aya::Ebpf::load()`）
2. 写入 `TARGET_PID` Map
3. 对 6 对 uprobe 逐一执行 `attach()`，记录成功/失败
4. 对 19 个 Tier 1 符号通过 `goblin` 检查是否存在于 ELF 中
5. 挂载 4 个 kprobe（tcp_sendmsg/recvmsg entry/return）
6. 挂载 1 个 tracepoint（raw_syscalls/sys_enter）
7. 输出验证结果

### 5.3 实时事件采集

验证完成后，自动进入 3 秒事件采集模式：

```rust
async fn collect_live_events(bpf: &mut aya::Ebpf, probe_type: &str) -> Result<()> {
    let cpus = online_cpus()?;

    // 为每种事件类型（uprobe/tcp/syscall）创建 AsyncPerfEventArray
    // 为每个 CPU 打开一个 ring buffer
    // 启动 tokio 任务异步读取事件
    // 等待 3 秒后 abort 所有任务
    // 打印事件计数汇总
}
```

`AsyncPerfEventArray` 基于 tokio 的 `epoll` 事件循环，当 ring buffer 有新数据时唤醒读取任务。每个 CPU 独立一个 ring buffer，避免跨 CPU 锁竞争。

---

## 六、ckb-probe rocksdb：RocksDB 实时监控

### 6.1 5 种核心监控操作

| 操作 | ELF 符号 | func_id | CKB 中的角色 |
|------|---------|---------|-------------|
| GET | `rocksdb_get_pinned_cf` | 1 | 主读路径（零拷贝固定读） |
| PUT | `rocksdb_transaction_put_cf` | 7 | 主写路径（事务写入） |
| WRITE | `rocksdb_write` | 4 | WriteBatch 原子提交 |
| ITER_NEW | `rocksdb_create_iterator_cf` | 5 | 创建迭代器 |
| TXN_COMMIT | `rocksdb_transaction_commit` | 8 | 事务提交 |

### 6.2 RocksDbCollector 数据流

```
内核态 BPF                           用户态 Collector
┌─────────────────┐                 ┌─────────────────────────────┐
│ uprobe_return:   │                 │ 每 N 秒轮询:                │
│   OP_STATS[fid]  │ ──(per-CPU)──→ │   read OP_STATS → merge     │
│   LATENCY_HIST   │ ──(per-CPU)──→ │   read LATENCY_HIST → merge │
│   SLOW_EVENTS    │ ──(perf buf)──→│   async consume → print     │
└─────────────────┘                 │                             │
                                    │ 计算:                       │
                                    │   QPS = Δcount / interval   │
                                    │   Avg = Δtotal_ns / Δcount  │
                                    │   P50/P99 = histogram walk  │
                                    └─────────────────────────────┘
```

### 6.3 PerCpuArray 合并算法

用户态从 PerCpuArray 读取时，aya 返回 `PerCpuValues<T>`——一个包含每 CPU 一个值的数组。合并逻辑：

```rust
fn read_all_snapshots(bpf: &mut aya::Ebpf) -> Result<Vec<OpSnapshot>> {
    let op_stats: PerCpuArray<_, OpStats> =
        PerCpuArray::try_from(bpf.map("OP_STATS").unwrap())?;

    for func_id in 0..MAX_FUNC_ID {
        if let Ok(per_cpu) = op_stats.get(&func_id, 0) {
            let s = &mut snapshots[func_id as usize];
            for v in per_cpu.iter() {      // 遍历所有 CPU 的值
                s.count += v.count;         // 求和
                s.total_ns += v.total_ns;   // 求和
                // min 取所有 CPU 中的最小值
                if v.min_ns != 0 && (s.min_ns == 0 || v.min_ns < s.min_ns) {
                    s.min_ns = v.min_ns;
                }
                // max 取所有 CPU 中的最大值
                if v.max_ns > s.max_ns {
                    s.max_ns = v.max_ns;
                }
            }
        }
    }
    // 同理合并 LATENCY_HIST...
}
```

### 6.4 百分位近似算法

从 log2 直方图近似 P50/P99：

```rust
fn percentile_from_hist(hist: &[u64; 64], pct: f64) -> u64 {
    let total: u64 = hist.iter().sum();
    let target = (total as f64 * pct / 100.0).ceil() as u64;
    let mut acc = 0u64;
    for (i, &count) in hist.iter().enumerate() {
        acc += count;
        if acc >= target {
            // 桶 i 覆盖 [2^i, 2^(i+1))，返回中点
            let lo = 1u64 << i;
            let hi = 1u64 << (i + 1);
            return (lo + hi) / 2;
        }
    }
    0
}
```

这给出的是**近似值**，精度受限于 log2 桶的粒度（每桶覆盖 2x 范围）。但对于监控场景，区分 "P99 是 5ms 还是 10ms" 已经足够。

### 6.5 增量计算

`OP_STATS` 和 `LATENCY_HIST` 是**累计值**（BPF 内核侧持续递增），用户态需要做增量计算来得到当前周期的 QPS 和延迟：

```rust
let delta_count = cur[id].count.saturating_sub(prev[id].count);  // 本周期新增调用
let delta_ns = cur[id].total_ns.saturating_sub(prev[id].total_ns);  // 本周期新增延迟

let qps = delta_count / interval;
let avg_us = delta_ns as f64 / delta_count as f64 / 1000.0;

// 直方图也需要增量
for i in 0..64 {
    delta_hist[i] = cur[id].hist[i].saturating_sub(prev[id].hist[i]);
}
```

### 6.6 四种输出模式

| 模式 | 触发方式 | 输出内容 |
|------|---------|---------|
| 默认 | `ckb-probe rocksdb --binary ... --pid ...` | 实时刷新统计表（QPS/Avg/P50/P99/Status） |
| 直方图 | `--histogram` | 统计表 + ASCII 延迟分布柱状图 |
| 慢操作 | `--slow --threshold <μs>` | 超阈值操作实时日志流 |
| JSON | `--json` | 机器可读 JSON 输出 |

### 6.7 优雅关闭

```rust
let running = Arc::new(AtomicBool::new(true));
let r = running.clone();
tokio::spawn(async move {
    let _ = tokio::signal::ctrl_c().await;
    r.store(false, Ordering::SeqCst);  // Ctrl+C 翻转标志
});
```

主循环和事件消费任务都检查 `running` 标志。当 Ctrl+C 触发时，所有任务有序退出，BPF 程序随 `aya::Ebpf` drop 自动卸载，不会在内核中留下残留探针。

---

## 七、构建系统

### 7.1 Workspace 布局

```toml
[workspace]
members = ["ckb-probe", "ckb-probe-common", "xtask"]
exclude = ["ckb-probe-ebpf"]  # eBPF 独立构建，需要 nightly + 特殊 target
resolver = "2"
```

`ckb-probe-ebpf` 被 exclude 的原因：它需要 `cargo +nightly` 和 `bpfel-unknown-none` target，而 workspace 的其他成员使用 stable Rust。

### 7.2 xtask 模式

`xtask` 是 Rust 社区的惯用做法——用一个 Rust 程序来管理构建流程：

```bash
cargo xtask build-ebpf   # 仅编译 eBPF
cargo xtask build         # 编译 eBPF + 用户态
```

`.cargo/config.toml` 中的别名使 `cargo xtask` 等价于 `cargo run --package xtask --`。

### 7.3 ckb-probe-common 的双重编译

`ckb-probe-common` 被编译两次：

1. **为 eBPF 编译**：`default-features = false`，启用 `no_std`，只编译结构体和枚举
2. **为用户态编译**：`default-features = true`（`user` feature），启用 `std` + `serde` + `aya::Pod`

这通过 `Cargo.toml` 的 feature 控制：

```toml
[features]
default = ["user"]
user = ["serde", "aya"]    # std 环境才需要的依赖
```

以及源码中的条件编译：

```rust
#![cfg_attr(not(feature = "user"), no_std)]          // eBPF: no_std
#[cfg(feature = "user")] use serde::{Serialize, ...}; // 仅用户态
#[cfg(feature = "user")] unsafe impl aya::Pod for OpStats {} // 仅用户态
```

---

## 八、数据验证

在 CKB v0.204.0 节点上的实际测试数据：

### 8.1 check 验证结果

```
环境检测：8/8 通过
eBPF 验证：27/33 通过（6 个失败为预期缺失的符号）
实时采集（3 秒）：2116 uprobe + 793 syscall 事件
```

### 8.2 rocksdb 监控数据

```
GET       : ~1500 QPS, avg ~700μs, P50 ~25μs, P99 ~12ms
PUT       :   ~50 QPS, avg ~8μs,   P50 ~6μs,  P99 ~25μs
WRITE     :   ~40 QPS, avg ~45μs,  P50 ~49μs, P99 ~98μs
ITER_NEW  :   ~55 QPS, avg ~17μs,  P50 ~12μs, P99 ~49μs
TXN_COMMIT:   ~15 QPS, avg ~100μs, P50 ~98μs, P99 ~197μs
```

GET 操作的高 P99（~12ms）与低 P50（~25μs）的巨大差异表明存在偶发的慢查询——可能与 RocksDB 的 compaction 或 block cache miss 相关，这正是 ckb-probe 要帮助诊断的问题。

---

*文档由 ckb-probe 开发组编写，基于 ckb-probe v0.1.0 源码。*
