# ckb-probe

基于 eBPF 的 CKB 全节点深度可观测性工具。

[English](README.md)

## 项目简介

ckb-probe 通过 eBPF（uprobe / kprobe / tracepoint）为 CKB 全节点提供应用语义级的实时性能洞察。

- **`check`** — 检测环境前置条件，挂载 eBPF 探针到运行中的 CKB 进程，实时采集事件。
- **`symbols`** — 扫描 CKB 二进制文件的 ELF 符号表，分析 uprobe 可挂载的探针目标。

## 功能特性

- **ELF 符号解析**：基于 `goblin` 解析 `.symtab` / `.dynsym`，自动识别二进制的 strip 状态和 DWARF 调试信息
- **RocksDB 链接方式检测**：自动判断 RocksDB 是静态链接（嵌入二进制）还是动态链接（librocksdb.so）
- **三级符号分类**：
  - **Tier 1** — RocksDB C API 符号（`extern "C"`，无 mangling），跨版本稳定，理想的 uprobe 目标（20 个追踪目标）
  - **Tier 2** — Rust 跨 crate 公开函数（mangled），存在于大多数自编译 release 版本中（21 个追踪目标）
  - **Tier 3** — 被内联/LTO 消除/crate 内部函数，release 构建中通常不可用（12 个追踪目标）
- **环境检测**：8 项环境检查，彩色 pass/fail 报告
- **eBPF 探针验证 + 实时事件采集**：
  - RocksDB uprobe/uretprobe 延迟测量（entry/return 配对，实时 μs 级延迟）
  - TCP kprobe（`tcp_sendmsg` / `tcp_recvmsg`）字节级监控
  - `sys_enter` tracepoint syscall 分布分析
  - 3 秒实时事件采集，按探针类型统计事件数量
- **多种输出格式**：彩色终端报告 / JSON 机器可读格式
- **灵活过滤**：按关键字子串过滤、按 Tier 级别过滤

## 构建

```bash
# 全量构建（eBPF + 用户态 CLI）
cargo xtask build

# 仅构建 eBPF 程序（需要 nightly + BPF target）
cargo xtask build-ebpf

# 仅构建用户态 CLI（需要 Rust 工具链）
cargo build --release
```

构建产物位于 `target/release/ckb-probe`。

## 使用方法

### 环境检测

```bash
# 快速环境检测（8 项）
ckb-probe check

# 附带 CKB 二进制符号验证
ckb-probe check --binary /path/to/ckb
```

### eBPF 验证 + 实时事件采集（需要 root 权限）

```bash
# 完整验证：挂载所有探针 + 采集 3 秒实时事件
ckb-probe check --binary /path/to/ckb --pid <CKB_PID>

# 指定探针类型
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe uprobe
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe kprobe
ckb-probe check --binary /path/to/ckb --pid <CKB_PID> --probe tracepoint
```

示例输出：

```
╔══════════════════════════════════════════════════════════════╗
║  ckb-probe eBPF validation                                 ║
╠══════════════════════════════════════════════════════════════╣
  ✅   rocksdb_get_pinned_cf   entry + return attached
  ✅   rocksdb_put             entry + return attached
  ✅   rocksdb_write           entry + return attached
  ✅ uprobe summary            latency pairs: 4/6, Tier 1 symbols: 15/19
  ✅ kprobe tcp_sendmsg_entry  attached to tcp_sendmsg
  ✅ tracepoint sys_enter      attached to raw_syscalls/sys_enter
╚══════════════════════════════════════════════════════════════╝

  ⏳ Collecting live events for 3 seconds...

  [uprobe] pid=3127545 tid=3127553 func=get_pinned_cf            latency=84.7μs
  [uprobe] pid=3127545 tid=3127553 func=write                    latency=44.9μs
  [uprobe] pid=3127545 tid=3127553 func=create_iterator_cf       latency=23.2μs
  [tcp]    pid=3127545 tid=3127556 dir=TX bytes=1471
  [syscall] pid=3127545 tid=3127565 nr=232 (epoll_wait)

  📊 Captured 1873 uprobe, 2 tcp, 621 syscall events in 3s
```

### 符号分析

```bash
# 分析 CKB 二进制的符号可用性
ckb-probe symbols /path/to/ckb

# JSON 输出
ckb-probe symbols /path/to/ckb --json

# 详细模式（显示 mangled 名称、虚拟地址、大小）
ckb-probe symbols /path/to/ckb --verbose

# 按 Tier 或关键字过滤
ckb-probe symbols /path/to/ckb --tier 1
ckb-probe symbols /path/to/ckb --filter transaction
```

### 查看帮助

```bash
ckb-probe --help
ckb-probe check --help
ckb-probe symbols --help
```

## 运行测试

```bash
cargo test --workspace
```

## 项目结构

```
ckb-probe/
├── Cargo.toml                  # workspace 根配置
├── ckb-probe-common/           # 共享类型定义
│   └── src/lib.rs              # eBPF 事件类型 + 符号分级/分类/注册表
├── ckb-probe/                  # 主 CLI 程序
│   └── src/
│       ├── main.rs             # 异步入口（tokio）
│       ├── cli.rs              # clap 命令行定义（check/symbols）
│       └── commands/
│           ├── check.rs        # 环境检测 + eBPF 验证 + 实时事件采集
│           └── symbols.rs      # ELF 符号分析引擎
├── ckb-probe-ebpf/             # eBPF 内核态程序（no_std）
│   └── src/main.rs             # uprobe/kprobe/tracepoint BPF 程序
└── xtask/                      # 构建辅助
    └── src/main.rs             # cargo xtask build-ebpf / build
```

## 符号分级说明

| 级别 | 来源 | 稳定性 | 用途 |
|------|------|--------|------|
| Tier 1 | RocksDB C API (`extern "C"`) | 跨版本稳定，无 mangling | 首选 uprobe 目标 |
| Tier 2 | Rust 跨 crate 公开函数 | 每次编译 hash 后缀不同，需动态解析 | 自编译版本可用 |
| Tier 3 | crate 内部/内联函数 | release 构建中通常被消除 | 不适合作为 uprobe 目标 |

## 环境检测项目

| # | 检测项 | 要求 |
|---|--------|------|
| 1 | 内核版本 | >= 5.8 |
| 2 | BPF 配置 | CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y, CONFIG_BPF_JIT=y |
| 3 | BTF 支持 | /sys/kernel/btf/vmlinux 存在 |
| 4 | 权限 | root 或 CAP_BPF |
| 5 | bpf() 系统调用 | 可用（非 ENOSYS） |
| 6 | uprobe 支持 | tracefs 中存在 uprobe_events 文件 |
| 7 | CKB 进程 | 检测到运行中的 ckb 进程 |
| 8 | CKB 符号 | 二进制中存在关键 RocksDB 符号（可选） |

## 路线图

- **Week 2**（已完成）：`ckb-probe symbols` — 二进制符号侦察
- **Week 3**（已完成）：eBPF 可行性验证 + 实时事件采集 + `ckb-probe check`
- **Week 4**（进行中）：RocksDB 深度追踪 — `ckb-probe rocksdb`，延迟直方图、慢操作告警、实时监控

## 许可证

MIT OR Apache-2.0
