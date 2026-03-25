# ckb-probe

基于 eBPF 的 CKB 全节点深度可观测性工具。

## 项目简介

ckb-probe 通过 eBPF（uprobe / kprobe / tracepoint）为 CKB 全节点提供应用语义级的实时性能洞察。当前已实现 `symbols` 子命令，用于扫描 CKB 二进制文件的 ELF 符号表，分析 uprobe 可挂载的探针目标。

## 功能特性

- **ELF 符号解析**：基于 `goblin` 解析 `.symtab` / `.dynsym`，自动识别二进制的 strip 状态和 DWARF 调试信息
- **RocksDB 链接方式检测**：自动判断 RocksDB 是静态链接（嵌入二进制）还是动态链接（librocksdb.so）
- **三级符号分类**：
  - **Tier 1** — RocksDB C API 符号（`extern "C"`，无 mangling），跨版本稳定，理想的 uprobe 目标（20 个追踪目标）
  - **Tier 2** — Rust 跨 crate 公开函数（mangled），存在于大多数自编译 release 版本中（21 个追踪目标）
  - **Tier 3** — 被内联/LTO 消除/crate 内部函数，release 构建中通常不可用（12 个追踪目标）
- **多种输出格式**：彩色终端报告 / JSON 机器可读格式
- **灵活过滤**：按关键字子串过滤、按 Tier 级别过滤

## 构建

```bash
# 需要 Rust 工具链（推荐 rustup 安装）
cargo build --release
```

构建产物位于 `target/release/ckb-probe`。

## 使用方法

### 基本用法

```bash
# 分析 CKB 二进制的符号可用性
ckb-probe symbols /path/to/ckb
```

### 输出示例

```
════════════════════════════════════════════════════════════════════════
   CKB Binary Symbol Analysis Report
   Binary: /path/to/ckb (128.5 MB)
   Format: ELF 64-bit x86_64
════════════════════════════════════════════════════════════════════════

── ELF Overview ──────────────────────────────────────────
  .symtab:        ✅ Present (523847 symbols)
  .dynsym:        ✅ Present (12 symbols)
  DWARF:          ❌ Not found
  Strip status:   debuginfo-stripped (.symtab retained)

── RocksDB Linkage ───────────────────────────────────────
  Method:         Static (bundled into CKB binary)
  Evidence:       No librocksdb.so in dynamic deps; 487 rocksdb_* in .symtab
  Assessment:     ✅ Ideal — C API symbols embedded in binary

── [Tier 1] Directly uprobe-attachable (extern "C", stable) ──
  ✅ rocksdb_get                                0x01a2b3c4  (128 B)
  ✅ rocksdb_get_pinned_cf                      0x01a2b4d8  (256 B)
  ...
  → 20 / 20 tracked targets found

── Summary ───────────────────────────────────────────────
  Tier 1:  20 / 20  (100%)  READY for uprobe ✅
  Tier 2:  15 / 21  ( 71%)  available in this binary
  Tier 3:  18 tracked functions not found
```

### 详细模式

显示 mangled 名称、虚拟地址、符号大小和描述信息：

```bash
ckb-probe symbols /path/to/ckb --verbose
# 或
ckb-probe symbols /path/to/ckb -v
```

### JSON 输出

适合管道处理和自动化分析：

```bash
# 输出完整 JSON 报告
ckb-probe symbols /path/to/ckb --json

# 配合 jq 查询 Tier 1 符号数量
ckb-probe symbols /path/to/ckb --json | jq '.tier1 | length'

# 查询 RocksDB 链接方式
ckb-probe symbols /path/to/ckb --json | jq '.rocksdb_linkage'
```

### 按 Tier 过滤

```bash
# 只显示 Tier 1（RocksDB C API 符号）
ckb-probe symbols /path/to/ckb --tier 1

# 只显示 Tier 2（Rust 函数符号）
ckb-probe symbols /path/to/ckb --tier 2

# 只显示 Tier 3（不可用的符号）
ckb-probe symbols /path/to/ckb --tier 3
```

### 按关键字过滤

大小写不敏感的子串匹配：

```bash
# 过滤包含 "transaction" 的符号
ckb-probe symbols /path/to/ckb --filter transaction

# 过滤包含 "iterator" 的符号，JSON 输出
ckb-probe symbols /path/to/ckb --filter iterator --json

# 组合使用：Tier 1 中包含 "get" 的符号
ckb-probe symbols /path/to/ckb --tier 1 --filter get
```

### 查看帮助

```bash
ckb-probe --help
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
│   └── src/lib.rs              # SymbolTier, SymbolCategory, ProbeTargets 等
├── ckb-probe/                  # 主 CLI 程序
│   └── src/
│       ├── main.rs             # 入口
│       ├── cli.rs              # clap 命令行定义
│       └── commands/
│           └── symbols.rs      # symbols 子命令核心实现
└── ckb-probe-ebpf/            # eBPF 探针程序（Week 3 实现）
```

## 符号分级说明

| 级别 | 来源 | 稳定性 | 用途 |
|------|------|--------|------|
| Tier 1 | RocksDB C API (`extern "C"`) | 跨版本稳定，无 mangling | 首选 uprobe 目标 |
| Tier 2 | Rust 跨 crate 公开函数 | 每次编译 hash 后缀不同，需动态解析 | 自编译版本可用 |
| Tier 3 | crate 内部/内联函数 | release 构建中通常被消除 | 不适合作为 uprobe 目标 |

## 路线图

- **Week 2**（已完成）：`ckb-probe symbols` 子命令，二进制符号侦察
- **Week 3**：eBPF 探针实现（rocksdb uprobe 延迟测量、kprobe 网络追踪、tracepoint 系统调用 Top-N）
- **Week 4+**：实时仪表盘、告警、生产环境部署

## 许可证

MIT OR Apache-2.0
