# ckb-probe 中期报告（Week 2–4）

> 里程碑 2 提前完成。EWMA 异常检测（原 Week 5）在 Week 4 交付。

## 1. 里程碑状态

| 里程碑 | 目标 | 状态 |
|--------|------|------|
| 里程碑 1（Week 3） | eBPF 可行性验证通过，`check` + `symbols` 交付 | ✅ 达成 |
| 里程碑 2（Week 5→4） | `ckb-probe rocksdb` 在测试网可用，含异常检测 | ✅ 提前达成 |

## 2. Week 2：二进制符号侦察

**交付物：** `ckb-probe symbols` 子命令（876 行）

扫描 CKB v0.205.0 官方 Release 和自编译版本，关键发现：

| 维度 | 官方 Release | 自编译 |
|------|-------------|--------|
| 文件大小 | 51.6 MB | 903.2 MB |
| `.symtab` 符号数 | 78,847 | 152,937 |
| 函数符号数 | 53,522 | 87,004 (+62.6%) |
| RocksDB C API 符号 | 151 | 155 |
| RocksDB 链接方式 | 静态 | 静态 |

**三级分类体系：**
- **Tier 1**（RocksDB C API，`extern "C"`）— 找到 15/20，跨版本稳定，理想 uprobe 目标
- **Tier 2**（Rust 跨 crate 公开函数）— 找到 8/21，hash 后缀每次编译不同
- **Tier 3**（内联 / LTO 消除）— release 构建中不可用

**Tier 2 噪声过滤：** `is_direct_match()` 通过 `<>` 嵌套深度追踪和前缀黑名单，过滤编译器生成的 drop glue、GenFuture、Box wrapper 等噪声符号。

## 3. Week 3：eBPF 可行性验证

**交付物：** `ckb-probe check` 子命令 + eBPF 内核态程序

四项验证全部通过：

| 验证项 | 结果 |
|--------|------|
| RocksDB uprobe/uretprobe 延迟测量 | ✅ 4 组 entry/return 配对挂载 |
| 多函数 uprobe（19 个 Tier 1 符号） | ✅ 15/19 确认可挂载 |
| TCP kprobe（tcp_sendmsg/recvmsg） | ✅ 4/4 挂载，实时字节捕获 |
| sys_enter tracepoint | ✅ syscall 分布采集成功 |

**`ckb-probe check` 功能：**
- 8 项环境检测（内核、BTF、BPF、权限、uprobe、CKB 进程、符号）
- 提供 `--binary` 和 `--pid` 时执行完整 eBPF 探针验证
- 3 秒实时事件采集，按探针类型统计数量

**里程碑 1 达成。**

## 4. Week 4：RocksDB 深度追踪 + EWMA 异常检测

**交付物：** `ckb-probe rocksdb` 子命令（1,156 行）— 核心监控模块

### 4.1 五种操作追踪

| 操作 | RocksDB 函数 | CKB 调用路径 | Bytes/s 来源 |
|------|-------------|-------------|--------------|
| GET | `rocksdb_get_pinned_cf` | Block/header/cell 查询 | uretprobe 读 PinnableSlice 偏移 8 的 `size_` |
| PUT | `rocksdb_transaction_put_cf` | 事务内单次写入 | entry probe 从 `ctx.arg(5)` 读 vlen |
| WRITE | `rocksdb_write` | WriteBatch 原子提交 | —（ABI 依赖，跳过） |
| ITER_NEW | `rocksdb_create_iterator_cf` | 范围扫描入口 | —（无 payload） |
| TXN_COMMIT | `rocksdb_transaction_commit` | 事务提交 | 每线程 `PUT_PENDING_BYTES` 累加器 |

**Bytes/s 验证：** PUT 和 TXN_COMMIT 显示相同的 3.2 KB/s — 完全符合预期："一个事务内的所有 PUT 在 commit 时被打包结算"。这是端到端正确性的强信号。

### 4.2 BPF Map 架构

| Map | 类型 | 容量 | 用途 |
|-----|------|------|------|
| `TARGET_PID` | HashMap | 8 | PID 过滤 |
| `UPROBE_START` | HashMap | 1024 | tid → (时间戳, func_id, size) |
| `OP_STATS` | PerCpuArray | 9 | 每操作 count/total_ns/bytes 聚合 |
| `LATENCY_HIST` | PerCpuArray | 576 | log2 分桶直方图（9 操作 × 64 桶） |
| `SLOW_EVENTS` | PerfEventArray | — | 超阈值事件 |
| `SLOW_THRESHOLD` | Array | 1 | 可配置阈值（纳秒） |
| `PUT_PENDING_BYTES` | HashMap | 1024 | 每线程 PUT 字节累加器 |

**设计选择 — PerCpuArray 而非 HashMap：** 避免跨 CPU 锁竞争。每个 CPU 独立写自己的 slot，用户态读时合并各 CPU 数据。

### 4.3 四种输出模式

**默认表格** — 实时 QPS / Avg / P50 / P99 / Bytes/s，1 秒刷新，表头自动探测 CKB 版本。

**`--histogram`** — log2 分桶延迟分布。揭示了 GET 的双峰延迟模式：
- 第一峰 ~16-65μs（Block Cache 命中）
- 第二峰 ~2-8ms（Cache miss → 磁盘 SST 查找）

聚合统计的 `Avg=1503μs` 完全无法揭示这一双峰结构 — 直方图模式正是为捕捉长尾真实形状而存在。

**`--slow --threshold N`** — 超阈值的单个操作，通过 PerfEventArray 推送（未超阈值时零开销）。显示时间戳、操作、延迟、数据量。Size 列揭示慢操作是来自数据搬运还是 I/O 瓶颈。

**`--json`** — 机器可读 JSONL 输出，含 `operations{}`、`anomalies[]`、`timestamp`、`pid`。可管道给 jq / Prometheus / ELK。

### 4.4 EWMA 异常检测（原 Week 5，提前交付）

**参数：**
- α = 0.05（缓慢适应，基线稳定）
- 预热期：300 秒（基线收集期间不告警）
- 三路触发：avg > 5× 基线 | P99 > 3× 基线 | P99 > 绝对上限
- 每操作绝对 P99 上限：GET 50ms、PUT 10ms、WRITE 50ms、ITER_NEW 5ms、TXN_COMMIT 100ms

**四项安全特性：**
1. 冷启动不误报（300 秒预热）
2. 瞬时抖动不误报（50μs 绝对底 + 异常期不更新基线）
3. 持续退化不漏报（绝对 P99 硬上限补盲）
4. 低 QPS 操作不被静默（5 秒滑动窗口降级）

**默认表格状态栏：**
```
  Status: ⏳ Warming up — Collecting baseline (174s remaining).
  Status: ✅ Normal — All latencies within baseline.
  ⚠️  ANOMALY DETECTED [13:42:08]
    → GET [P99+CAP]  avg 1842.3μs (base 312.4μs, ×5.9)
    → Probable cause: Compaction storm (WRITE P99 = 4.7ms)
```

**里程碑 2 达成（提前 1 周）。**

## 5. 核心数据结构

```rust
// 内核侧，per-CPU 聚合
struct OpStats {
    count: u64,       // 操作次数
    total_ns: u64,    // 延迟总和（纳秒）
    bytes_total: u64, // 数据量总和
}

// 内核→用户态，逐事件
struct SlowEvent {
    func_id: u32,      // 哪种 RocksDB 操作
    latency_ns: u64,   // 实测延迟
    size: u64,          // 数据量（0 表示未追踪）
    ts: u64,            // bpf_ktime_get_ns 时间戳
}
```

## 6. 真实 CKB 测试网验证

所有功能在 CKB v0.204.0 测试网节点（24 核 Linux 6.8）上测试：
- 四种输出模式产出真实数据
- EWMA 异常检测在自然 compaction 事件上触发
- Bytes/s 一致性验证（PUT = TXN_COMMIT 吞吐量）
- BPF verifier 无修改通过所有程序

## 7. 剩余工作（Week 5–8）

| 任务 | 说明 |
|------|------|
| 性能优化 | perf buffer 大小调优、BPF map 容量缩减 |
| S-4 进程重启恢复 | CKB 重启后自动重连 |
| Docker 可复现环境 | Dockerfile + 演示脚本 + env-check |
| P-1~P-4 性能测试 | CPU / RSS / 事件丢失 / 同步退化 |
| 48h 稳定性测试（S-1~S-4） | 长时间运行验证 |
| CLI 润色 | clap 帮助文案、错误退出码 |
| 结项报告 + v0.1.0 发布 | 文档、打包 |

