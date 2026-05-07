# ckb-probe 代码架构

> 三个 crate 协同工作：`ckb-probe-common` 定义共享类型，`ckb-probe-ebpf` 运行在内核态，`ckb-probe`（用户态）编排一切。

## 1. Crate 关系

```
┌─────────────────────────────────────────────────────────────────┐
│                           用户态                                 │
│                                                                 │
│  ckb-probe/src/commands/rocksdb.rs                              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ 1. 加载 eBPF ELF 二进制                                   │   │
│  │ 2. 向 map 写入 TARGET_PID + SLOW_THRESHOLD                │   │
│  │ 3. 把 uprobe/uretprobe 挂到 CKB 二进制的符号上             │   │
│  │ 4. 每 N 秒轮询 OP_STATS / LATENCY_HIST                    │   │
│  │ 5. 从 RingBuf 批量读慢操作事件（slow 模式）                │   │
│  │ 6. 计算 QPS / Avg / P50 / P99 / Bytes/s / 异常检测         │   │
│  │ 7. 渲染表格 / 直方图 / 慢操作 / JSON                       │   │
│  └──────────────────────────────────────────────────────────┘   │
│         │ 使用类型                     │ 读取 map               │
│         ▼                              ▼                        │
│  ckb-probe-common/src/lib.rs    ckb-probe-ebpf/src/main.rs     │
│  ┌────────────────────┐         （编译为 BPF ELF，              │
│  │ OpStats             │           加载到内核）                  │
│  │ SlowEvent           │                                        │
│  │ RocksDbFunc enum    │                                        │
│  │ MAX_FUNC_ID = 9     │                                        │
│  │ HIST_BUCKETS = 64   │                                        │
│  └────────────────────┘                                         │
│         ▲ 使用类型                                               │
├─────────┼───────────────────────────────────────────────────────┤
│         │                内核态                                   │
│                                                                 │
│  ckb-probe-ebpf/src/main.rs                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ BPF 程序（内核在每次 RocksDB 调用时自动触发）：             │   │
│  │                                                          │   │
│  │ uprobe_entry:                                            │   │
│  │   if pid != TARGET_PID → return                          │   │
│  │   UPROBE_START[tid] = (时间戳, func_id, size)             │   │
│  │                                                          │   │
│  │ uretprobe_return:                                        │   │
│  │   (start_ts, func_id, size) = UPROBE_START[tid]          │   │
│  │   latency = now - start_ts                               │   │
│  │   OP_STATS[func_id].count++                              │   │
│  │   OP_STATS[func_id].total_ns += latency                  │   │
│  │   LATENCY_HIST[func_id * 64 + log2(latency)]++          │   │
│  │   if latency > SLOW_THRESHOLD → RingBuf.output(event)   │   │
│  │   delete UPROBE_START[tid]                               │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## 2. ckb-probe-common（共享类型）

`#![no_std]` 兼容——内核态和用户态都使用。

### 核心数据结构

```rust
// 每操作聚合统计（PerCpuArray 中，每个 func_id 一个）
struct OpStats {
    count: u64,       // 调用次数
    total_ns: u64,    // 延迟总和
    min_ns: u64,
    max_ns: u64,
    bytes_total: u64, // 数据量总和（未追踪的为 0）
}

// 单个慢操作事件（延迟超阈值时通过 RingBuf 发送）
struct SlowEvent {
    pid: u32,
    tid: u32,
    func_id: u32,     // 哪种 RocksDB 操作（见 RocksDbFunc 枚举）
    latency_ns: u64,
    size: u64,         // 数据量
    ts: u64,           // bpf_ktime_get_ns 时间戳
}

// func_id 编号到操作名的映射
enum RocksDbFunc {
    GetPinnedCf = 1,       // GET
    Put = 2,
    Delete = 3,
    Write = 4,             // WRITE
    NewIteratorCf = 5,     // ITER_NEW
    MultiGetCf = 6,
    TransactionPutCf = 7,  // PUT
    TransactionCommit = 8, // TXN_COMMIT
}

const MAX_FUNC_ID: u32 = 9;   // OP_STATS 数组大小
const HIST_BUCKETS: u32 = 64;  // log2 桶，覆盖 1ns 到 2^63 ns
```

### 仅用户态类型（`#[cfg(feature = "user")]`）

- `SymbolTier` / `SymbolCategory` — 用于 `ckb-probe symbols` 分类
- `SymbolReport` / `SymbolInfo` — 符号分析输出
- `ProbeTargets` — 静态注册表：20 个 Tier 1 + 21 个 Tier 2 + 12 个 Tier 3 目标

## 3. ckb-probe-ebpf（内核态）

### BPF Map 布局

| Map | 类型 | 大小 | 方向 | 用途 |
|-----|------|------|------|------|
| `TARGET_PID` | HashMap | 8 | 用户→内核 | 只追踪这个 PID |
| `UPROBE_START` | HashMap | 1024 | 内核内部 | tid → (时间戳, func_id, size)，entry/return 配对 |
| `OP_STATS` | PerCpuArray | 9 | 内核→用户（轮询） | 每操作聚合 count/total_ns/bytes |
| `LATENCY_HIST` | PerCpuArray | 576 | 内核→用户（轮询） | log2 直方图（9 操作 × 64 桶） |
| `SLOW_EVENTS` | RingBuf | 256KB | 内核→用户（批量） | 超阈值慢操作事件 |
| `SLOW_THRESHOLD` | Array | 1 | 用户→内核 | 阈值（纳秒） |
| `PUT_PENDING_BYTES` | HashMap | 1024 | 内核内部 | 每线程字节累加器，用于 TXN_COMMIT |

### Entry/Return 配对逻辑

每个被监控的 RocksDB 函数都有一个 uprobe（入口）和 uretprobe（出口）：

```
CKB 调用 rocksdb_get_pinned_cf(db, cf, key, klen, &errptr)
    │
    ▼ 内核触发 uprobe
    uprobe_entry(func_id=1):
        if pid != TARGET_PID → 跳过
        UPROBE_START[tid] = (bpf_ktime_get_ns(), 1, 0)
    │
    │ ... 函数在 CKB 内执行 ...
    │
    ▼ 内核触发 uretprobe
    uprobe_return(ctx):
        (start_ts, func_id, entry_size) = UPROBE_START[tid]
        latency = now - start_ts
        value_size = bpf_probe_read_user(ctx.ret() + 8)  // PinnableSlice.size_

        // 同时写入 3 个 map：
        OP_STATS[1].count++; OP_STATS[1].total_ns += latency; OP_STATS[1].bytes_total += value_size
        LATENCY_HIST[1*64 + log2(latency)]++
        if latency > SLOW_THRESHOLD[0] → SLOW_EVENTS.output(SlowEvent{...})

        delete UPROBE_START[tid]
```

### 每操作的特殊处理

每个操作对有各自的 entry/return 逻辑来提取字节数：

| 操作 | 入口 | 出口 |
|------|------|------|
| GET | `uprobe_entry(1)` — 不需要参数 | `ctx.ret()` → PinnableSlice 指针 → 偏移 8 读 `size_` |
| PUT | `ctx.arg(5)` 读 `vlen` + 累加到 `PUT_PENDING_BYTES[tid]` | 标准 return |
| WRITE | `uprobe_entry(4)` — 无字节（WriteBatch 内部） | 标准 return |
| ITER_NEW | `uprobe_entry(5)` — 无字节 | 标准 return |
| TXN_COMMIT | 快照 `PUT_PENDING_BYTES[tid]` 然后清零 | 标准 return |

## 4. ckb-probe（用户态）— rocksdb.rs

### 启动流程

```rust
pub async fn run(args: RocksdbArgs) -> Result<()> {
    // 1. 加载 BPF ELF
    let data = std::fs::read("ckb-probe-ebpf/.../ckb-probe-ebpf")?;
    let mut bpf = aya::Ebpf::load(&data)?;

    // 2. 配置 map
    HashMap::try_from(bpf.map_mut("TARGET_PID"))?.insert(args.pid, 1, 0)?;
    Array::try_from(bpf.map_mut("SLOW_THRESHOLD"))?.set(0, threshold_ns, 0)?;

    // 3. 把 5 对 uprobe 挂到 CKB 二进制符号上
    for (entry_fn, ret_fn, symbol, ...) in MONITOR_PROBES {
        let uprobe = bpf.program_mut(entry_fn).try_into::<UProbe>()?;
        uprobe.load()?;
        uprobe.attach(Some(symbol), 0, &binary, None)?;  // ← 内核 hook 符号
        // ... uretprobe 同理 ...
    }

    // 4. 进入监控循环（表格 / 直方图 / 慢操作 / JSON）
    loop { ... }
}
```

### 数据采集循环（表格 / 直方图 / JSON 模式）

```
每 N 秒：
  1. 读 OP_STATS PerCpuArray → 合并各 CPU 值 → 得到当前总量
  2. 读 LATENCY_HIST PerCpuArray → 合并各 CPU 值 → 得到当前直方图
  3. 减去上次快照 → 得到本周期增量
  4. 计算：
     - QPS = 增量 count / 间隔
     - Avg = 增量 total_ns / 增量 count
     - P50/P99 = 在增量直方图中找累积计数达到 50%/99% 的桶
     - Bytes/s = 增量 bytes / 间隔
  5. 喂给 EWMA 异常检测器
  6. 渲染输出
```

### 慢操作模式（RingBuf）

```
单线程读取器：
  AsyncFd 包装 RingBuf 文件描述符
  每 100ms（或有数据时）：
    while ring.next() 有数据：
      解析 SlowEvent
      通过 mpsc channel 发给渲染器

渲染器：
  维护最近 8 条慢操作的 VecDeque
  每 N 秒重绘表格：最新事件 + 累计计数 + BPF loss 计数器
```

### EWMA 异常检测

```
每个周期，对每个操作：
  if 预热中 (< 300s)：
    baseline[op] = 只更新 EWMA，不告警
  else：
    effective_base = max(baseline[op], 50μs)  // 绝对底线
    if 当前 avg > 5× effective_base → 告警（AVG 触发）
    if 当前 p99 > 3× p99_baseline   → 告警（P99 触发）
    if 当前 p99 > hard_cap[op]      → 告警（CAP 触发）
    if 任一触发器触发：
      不更新 baseline（防止被持续退化吸收）
    else：
      baseline[op] = 0.05 × 当前值 + 0.95 × baseline
```

### S-4 进程重启恢复

```
后台线程（每秒）：
  检查 /proc/{pid} 是否存在
  if 不存在：
    设置 running = false → 监控循环退出
    释放 BPF 资源

  轮询 /proc/*/exe 找同一 binary
  if 找到新 PID：
    重新加载 BPF ELF
    重新写入 TARGET_PID
    重新 attach 所有 uprobe
    恢复监控循环
```

## 5. 数据流总览

```
CKB 进程                       内核                            ckb-probe 用户态
──────────                     ────                            ────────────────
rocksdb_get_pinned_cf() ──→ uprobe 触发 BPF 程序
                              │
                              ├→ UPROBE_START[tid] = 时间戳
                              │  （函数执行中...）
                              ├→ latency = now - 时间戳
                              ├→ OP_STATS[1] += {count, ns, bytes}  ──→ 每 Ns 轮询 → QPS/Avg/P50/P99
                              ├→ LATENCY_HIST[bucket]++              ──→ 每 Ns 轮询 → 直方图
                              └→ if 慢: RingBuf.output(event)       ──→ 100ms 批量读 → 慢操作表
```

所有三条输出路径都源自同一次 uprobe/uretprobe 执行。不同模式的区别只是用户态读哪个 map。
