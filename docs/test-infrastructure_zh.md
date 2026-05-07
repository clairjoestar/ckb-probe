# ckb-probe 测试基础设施指南

> **范围：仅 CKB testnet，永远不涉及 mainnet。**

---

## 1. 概览

ckb-probe 的测试分为两大类：

| 类别 | 指标 | 耗时 | 目的 |
|------|------|------|------|
| **性能测试 (P-1 ~ P-4)** | CPU / 内存 / 事件丢失 / 同步退化 | ~4.5h | 量化 probe 对 CKB 的运行时开销 |
| **稳定性测试 (S-1 ~ S-4)** | 无崩溃 / 无泄漏 / 无内核警告 / 重启恢复 | 48h | 验证长时间运行的可靠性 |

### 架构

```
┌─────────────────────────────────────────────────────┐
│                    宿主机 / Docker                    │
│                                                     │
│  ┌──────────┐    uprobe/uretprobe    ┌───────────┐  │
│  │   CKB    │◄──────────────────────│ ckb-probe │  │
│  │ (testnet)│    kprobe/tracepoint   │  (eBPF)   │  │
│  └──────────┘                        └───────────┘  │
│       │                                    │        │
│       ▼                                    ▼        │
│  data/db (RocksDB)                  /tmp/perf-run   │
│                                    REPORT.txt       │
└─────────────────────────────────────────────────────┘
```

---

## 2. 前置条件

| 要求 | 最低版本 | 检查方式 |
|------|----------|----------|
| Linux 内核 | ≥ 5.8 | `uname -r` |
| BTF 支持 | — | `/sys/kernel/btf/vmlinux` 存在 |
| Docker | ≥ 20.10 | `docker --version` |
| 可用内存 | ≥ 4 GB | `free -g` |
| 可用磁盘 | ≥ 20 GB | `df -h` |

一键检查：

```bash
./docker/env-check.sh
```

---

## 3. 性能测试 (P-1 ~ P-4)

### 3.1 指标定义

| 编号 | 指标 | 预算 | 测量方法 |
|------|------|------|----------|
| P-1 | 附加 CPU 使用率 | ≤ 3% | 1h 窗口内 CKB %CPU 差值 (with vs without probe) |
| P-2 | ckb-probe RSS | ≤ 50 MB | 持续监控期间 VmRSS |
| P-3 | BPF 事件丢失率 | < 0.1% | PerfEventArray 丢失计数器 |
| P-4 | 同步速度退化 | < 1% | 2h IBD 窗口 blocks/min 对比 |

### 3.2 如何制造 IBD 工作量

在 tip 附近做 A/B 对比不准——出块稀疏，RocksDB 操作密度低（~500/s），P-4 的 blocks/min 波动大。

**解决方案：让节点落后于网络 tip。** 停止 CKB 几个小时（或使用一份已落后的节点数据），再启动时节点需要追赶网络 tip，产生真正的 IBD 工作量。

```
停止 CKB 前：  节点 tip = H = 网络 tip
停止 N 小时后：网络 tip = H + N×360（testnet ~10s/block）
启动 CKB：     节点从 H 开始 IBD 追赶 → 高密度 RocksDB 操作
```

停止时间越长，IBD 工作量越大。建议至少停 2 小时（~720 blocks）。如果手头有一份落后几天的节点数据（例如 15 天前的备份），效果更好，可以直接使用。

### 3.3 运行完整 P-1~P-4 测试

**前提：CKB 节点落后于网络 tip**（停机过几个小时，或使用旧数据）。

#### 宿主机直接运行

```bash
# 确保 CKB 在运行且落后于 tip
./docker/scripts/perf/perf-run-orchestrator.sh
```

#### Docker 容器内运行

```bash
# 确保宿主机 CKB 在运行且落后于 tip
docker run -d --name perf-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest perf

# 查看进度
docker logs -f perf-test
cat /tmp/perf-run/progress.log

# 查看最终报告
cat /tmp/perf-run/REPORT.txt
```

#### 严格 P-4 对比（单独跑 Phase A / Phase B）

两个 phase 都需要从相同的 IBD 状态开始。先解压全新数据（不启动 CKB），脚本内自动启动并立刻 attach：

```bash
# Phase A（with-probe）：解压全新数据，然后：
./docker/scripts/perf/perf-phase-a.sh /root/ckb-testnet

# Phase B（baseline）：重新解压全新数据，然后：
./docker/scripts/perf/perf-phase-b.sh /root/ckb-testnet
```

**测试流程（总计 ~4 小时）：**

```
Phase A: with-probe (2h)
  ├── 脚本内启动 CKB → 立即 attach probe
  ├── 采集 P-1/P-2/P-3/P-4
  └── 停止

Phase B: baseline (2h)（重新解压后）
  ├── 脚本内启动 CKB（无 probe）
  ├── 采集 P-1 baseline, P-4 baseline
  └── 停止
```

**测试期间监控命令：**

```bash
# 进度
tail -5 /tmp/perf-run/progress.log

# P-2 当前 RSS
tail -1 /tmp/perf-run/p2-rss.log | awk '{printf "RSS: %.1f MB\n", $2/1024}'

# P-3 事件丢失
grep -a "BPF event loss" /tmp/perf-run/probe-slow.log | tail -1

# P-4 同步采样
tail -3 /tmp/perf-run/p4-with-probe.log
wc -l /tmp/perf-run/p4-with-probe.log  # 目标: 121 行
```

### 3.5 读懂报告

最近一次测试结果（2026-04-15，Docker 容器内，真实 IBD 工作负载）：

| 指标 | 结果 | 预算 | 状态 |
|------|------|------|------|
| P-1 CPU 附加 | +1.29%（相对值） | ≤ 3% | ✅ PASS |
| P-2 RSS 内存 | 22.89 MB（稳定无增长） | ≤ 50 MB | ✅ PASS |
| P-3 事件丢失 | 0 / 20,034,457 (0.0000%)，峰值 13K/s | < 0.1% | ✅ PASS |
| P-4 同步退化 | -0.86%（反而略快） | < 1% | ✅ PASS |

```
P-1   附加 CPU 使用率 ≤ 3% (IBD 高峰期，relative)
  baseline %CPU mean       : 318.45%
  with-probe %CPU mean     : 322.56%
  relative delta           : +1.29%
  status                   : ✅ PASS
```

- **relative delta** 是相对增幅 `(with-probe - baseline) / baseline × 100%`
- 多核机器上 %CPU 可超过 100%（pidstat 报告的是所有核加总，24 核最高 2400%）

> **注意：** P-2 之前因 perf buffer 分配过大（1024 pages/CPU × 24 CPU = 96 MB）曾失败。
> 已修复为 16 pages/CPU，RSS 从 87.9 MB 降至 22.9 MB 并保持稳定。

### 3.6 单项快速测试

不想跑完整 4h？可以单独跑某一项：

```bash
# P-1: CPU 开销 (1 分钟快速验证)
./docker/scripts/perf/p1-cpu.sh baseline 60
./docker/scripts/perf/p1-cpu.sh with-probe 60
./docker/scripts/perf/p1-cpu.sh compare

# P-2: RSS 内存（持续监控，Ctrl+C 停止后输出 verdict）
./docker/scripts/perf/p2-rss.sh

# P-3: BPF 事件丢失率（5 分钟，需要 db_bench）
./docker/scripts/perf/p3-stress.sh 300
./docker/scripts/perf/p3-stress.sh 300 --no-db-bench   # 不用 db_bench

# P-4: 同步速度
./docker/scripts/perf/p4-sync.sh baseline 5   # 5 分钟 baseline
./docker/scripts/perf/p4-sync.sh with-probe 5  # 5 分钟 with-probe
./docker/scripts/perf/p4-sync.sh compare
```

---

## 4. 稳定性测试 (S-1 ~ S-4)

### 4.1 指标定义

| 编号 | 指标 | 判定标准 | 测量方法 |
|------|------|----------|----------|
| S-1 | 48h 无崩溃 | 0 crash/panic/restart | 进程存活检查 + stderr 扫描 |
| S-2 | 内存无泄漏 | RSS 增长 ≤ 5 MB | avg(最后1h RSS) - avg(最初1h RSS) |
| S-3 | 无内核 BPF 警告 | 0 new dmesg 警告 | 定时 diff dmesg |
| S-4 | 进程重启恢复 | 重连时间 < 60s | T+24h 主动重启 CKB |

### 4.2 运行

```bash
# 完整 48 小时测试
./docker/scripts/stability/stability-48h.sh

# 缩短测试（例如 2 小时验证脚本正确性）
DURATION_HOURS=2 ./docker/scripts/stability/stability-48h.sh

# 自定义采样间隔
SAMPLE_SECS=10 ./docker/scripts/stability/stability-48h.sh
```

### 4.3 数据采集

每 10 秒采样一次，48 小时产生 **17,280 个数据点**：

| 文件 | 内容 | 格式 |
|------|------|------|
| `timeseries.tsv` | 时序指标 | `ts probe_cpu% probe_rss_kb ckb_cpu% ckb_rss_kb` |
| `events.tsv` | 每操作指标 | `ts op qps avg_us p50_us p99_us bps` |
| `probe-stderr.log` | ckb-probe 错误输出 | 文本 |
| `probe-json.log` | ckb-probe JSON 输出 | JSON lines |
| `dmesg-start.log` | 起始 dmesg | 文本 |
| `dmesg-end.log` | 结束 dmesg | 文本 |
| `s4-restart.log` | S-4 重启测试日志 | 文本 |

### 4.4 S-4 自动重启测试

脚本在 T+24h（测试中点）自动执行：

```
T+24:00:00  停止 CKB (SIGTERM)
T+24:00:10  重启 CKB (./ckb run)
T+24:00:12  ckb-probe 检测到新 PID → 自动重连
T+24:00:12  记录重连耗时: 2s ✅
```

**已在真实 CKB 节点上验证通过（2026-04-13）：**

```
  Monitoring 5 operations on PID 3310428 ...
  ⚠ Target process (PID 3310428) exited. Waiting for CKB to restart...
  ✅ CKB restarted (new PID 673651). Reattaching probes...
  Monitoring 5 operations on PID 673651 ...
```

ckb-probe 的 S-4 实现原理（`rocksdb.rs`）：
1. 后台线程每秒检查 `/proc/{pid}` 是否存在
2. 进程退出 → 停止当前监控循环，释放 BPF 资源
3. 轮询 `/proc/*/exe` 查找同一 binary 的新进程
4. 发现新 PID → 重新加载 BPF、重新 attach uprobe → 继续监控
5. 表头 PID 自动更新，数据无缝恢复

### 4.5 生成报告

```bash
# 测试完成后自动生成，或手动重新生成
./docker/scripts/stability/generate-report.sh /tmp/stability-<timestamp>/
```

**报告内容（按 main_proj.md 6.5 节规范）：**

1. **S-1 ~ S-4 判定表** — 四项 PASS/FAIL 总览
2. **时序指标图表** — CPU%、RSS、P99 延迟、事件吞吐量（gnuplot PNG 或 ASCII）
3. **资源消耗汇总表** — Min / Max / Avg / P99 + 与阈值对比
4. **事件捕获保真度** — 总生成 vs 总捕获，按操作类型分解
5. **延迟分布直方图** — 五种操作的 log2 分桶直方图 + CDF
6. **案例分析 1：IBD 写入模式** — PUT/WRITE 吞吐量随链增长的演变
7. **案例分析 2：Compaction 延迟尖峰** — before/during/after 延迟 + 异常告警
8. **复现说明** — 内核版本、CKB 版本、硬件配置、复现命令

---

## 5. Docker 部署

### 5.1 前提：Docker 代理配置

如果宿主机通过代理访问网络，Docker daemon 默认**不继承**环境变量中的代理设置，需要单独配置：

```bash
# 1. 配置 Docker daemon 代理（拉镜像用）
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://your-proxy:port"
Environment="HTTPS_PROXY=http://your-proxy:port"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF

# 2. 配置 Docker client 代理（build 时传给容器）
mkdir -p ~/.docker
cat > ~/.docker/config.json <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "http://your-proxy:port",
      "httpsProxy": "http://your-proxy:port",
      "noProxy": "localhost,127.0.0.1"
    }
  }
}
EOF

# 3. 重启 Docker
systemctl daemon-reload && systemctl restart docker

# 4. 验证
docker info | grep -i proxy
```

### 5.2 构建镜像

镜像通过两阶段构建：
1. **Stage 1** — 从 `rust:latest` 编译 ckb-probe（userspace + eBPF）+ db_bench
2. **Stage 2** — `ubuntu:24.04` 最小运行时，装入 binary + 脚本

```bash
# 在项目根目录构建（约 10-15 分钟，取决于网速和编译速度）
docker build -f docker/Dockerfile -t ckb-probe:latest .

# 确认镜像
docker images ckb-probe
```

**关键设计：CKB binary 和数据通过 bind mount 从宿主机挂载，不包含在镜像内。** CKB testnet 数据 ~242 GB，且 binary 路径必须与宿主机进程 exe 路径一致才能 attach uprobe。镜像只包含 ckb-probe + db_bench + 脚本。

### 5.3 单容器模式（监控宿主机 CKB）

宿主机上已有运行中的 CKB 节点时，容器作为监控 sidecar 运行：

```bash
docker run --rm --privileged --pid host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb:/root/ckb:ro \
  -v /root/data:/data:ro \
  -v /tmp/demo-output:/tmp/perf-run \
  -e CKB_BIN=/root/ckb \
  ckb-probe:latest <command>
```

**关键参数说明：**

| 参数 | 用途 |
|------|------|
| `--privileged --pid host` | eBPF 需要特权模式 + 共享宿主机 PID namespace |
| `-v /root/ckb:/root/ckb:ro` | 挂载宿主机 CKB binary（路径必须与进程 exe 一致，uprobe 才能 attach） |
| `-v /root/data:/data:ro` | 挂载宿主机 CKB 数据目录 |
| `-e CKB_BIN=/root/ckb` | 告诉容器内脚本使用宿主机路径的 CKB binary |

> **为什么要挂载 CKB binary 且路径必须一致？**
> uprobe 通过 binary 路径 attach 到进程。容器内自带的 CKB 在 `/usr/local/bin/ckb`，但宿主机进程的 exe 是 `/root/ckb`。路径不匹配则 uprobe 无法 hook，采集不到数据。因此必须把宿主机 binary 按原路径挂载进容器。

### 5.4 演示脚本

六个演示脚本：

| 脚本 | 用途 | 耗时 |
|------|------|------|
| `demo-check` | 环境检查 + eBPF 验证 + 符号分析 | < 30s |
| `demo-normal [秒数]` | 正常监控 + JSON 快照 | 默认 5min |
| `demo-table [秒数]` | 默认表格模式（QPS / Avg / P50 / P99 / Bytes/s） | 默认 60s |
| `demo-histogram [秒数]` | 延迟分布直方图模式（log2 分桶） | 默认 60s |
| `demo-slow [秒数] [阈值μs]` | 慢操作捕获模式 | 默认 60s |
| `demo-stress [条目数]` | db_bench 压力注入 + 异常检测 | 2-3 min |

```bash
# 运行示例（单容器模式，监控宿主机 CKB）
DOCKER_RUN="docker run --rm --privileged --pid host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb:/root/ckb:ro \
  -v /root/data:/data:ro \
  -v /tmp/demo-output:/tmp/perf-run \
  -e CKB_BIN=/root/ckb \
  ckb-probe:latest"

$DOCKER_RUN demo-check             # 环境 + 符号检查
$DOCKER_RUN demo-table 30          # 30 秒表格模式
$DOCKER_RUN demo-histogram 30      # 30 秒直方图模式
$DOCKER_RUN demo-slow 30 500       # 30 秒慢操作（阈值 500μs）
$DOCKER_RUN demo-normal 60         # 1 分钟 JSON 监控
$DOCKER_RUN demo-stress 100000     # db_bench 10 万条压力测试
$DOCKER_RUN bash                   # 进入容器交互式 shell
```

**demo-stress** 使用 `db_bench` 注入 RocksDB 负载（fillrandom 4KB×10万条，4 线程并发），通过磁盘 I/O 竞争使 CKB 的 RocksDB 延迟上升，触发 ckb-probe 的慢操作捕获和异常检测。镜像内已编译好 db_bench。

### 5.5 镜像导出与分发

```bash
# 导出为文件
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz

# 在另一台机器导入
docker load < ckb-probe-latest.tar.gz
```

---

## 6. 案例研究

### 6.1 Case 1: IBD 写入模式分析

捕获 Initial Block Download 期间 RocksDB 的写放大模式：

```bash
./docker/scripts/case/case-1-ibd-write-pattern.sh
```

- 从 snapshot 启动 CKB（全新 IBD）
- 监控 30 分钟，10 秒采样
- 输出 PUT/WRITE 吞吐量和延迟的时间序列
- 分析随链高度增长的写放大趋势

### 6.2 Case 2: Compaction Storm 捕获

捕获 RocksDB compaction 导致的延迟飙升：

```bash
./docker/scripts/case/case-2-compaction-storm.sh
```

- 使用 `ckb.toml.aggressive` 配置降低 compaction 触发阈值
- 监控直到 ANOMALY DETECTED 事件出现
- 输出 before / during / after 延迟对比
- 展示 ckb-probe 的异常检测能力

---

## 7. 文件结构

```
ckb-probe/
├── .dockerignore
│
├── docs/                                    # ← 所有文档集中于此
│   ├── test-infrastructure.md               # 本文档：测试基础设施指南
│   ├── technical-deep-dive.md               # eBPF 技术深度分析
│   ├── docker-quickstart.md                 # Docker 快速入门
│   ├── CASE_STUDY_BUNDLE.md                 # 案例研究完整参考
│   ├── report-week2-symbol-analysis.md      # Week 2: 符号分析报告
│   ├── report-week2-symbol-analysis_zh.md
│   ├── report-week3-ebpf-validation.md      # Week 3: eBPF 验证报告
│   ├── report-week3-ebpf-validation_zh.md
│   ├── weekly-report-week2_zh.md            # 周报
│   ├── weekly-report-week3_zh.md
│   └── weekly-report-week4_zh.md
│
├── docker/                                  # Docker 构建 + 全部脚本
│   ├── Dockerfile                           # 两阶段构建 (rust + ubuntu)
│   ├── entrypoint.sh                        # 容器入口分发器
│   ├── env-check.sh                         # 宿主机环境检查
│   ├── README.md                            # Docker 快速说明
│   ├── ckb-config/
│   │   └── ckb.toml.aggressive              # Compaction 触发配置
│   └── scripts/                             # ← 所有脚本统一在此
│       ├── perf/                             # 性能测试 (P-1~P-4)
│       │   ├── perf-run-orchestrator.sh      #   全量 4h 测试（live node）
│       │   ├── perf-phase-a.sh               #   单独 Phase A（with-probe）
│       │   ├── perf-phase-b.sh               #   单独 Phase B（baseline）
│       │   ├── p1-cpu.sh                     #   单项 CPU 测试
│       │   ├── p2-rss.sh                     #   单项 RSS 测试
│       │   ├── p3-stress.sh                  #   单项事件丢失测试
│       │   └── p4-sync.sh                    #   单项同步测试
│       ├── stability/                        # 稳定性测试 (S-1~S-4)
│       │   ├── stability-48h.sh              #   48h 连续测试
│       │   └── generate-report.sh            #   报告生成器
│       ├── demo/                             # 演示脚本
│       │   ├── demo-check.sh                 #   环境 + 符号检查
│       │   ├── demo-table.sh                 #   默认表格模式
│       │   ├── demo-histogram.sh             #   延迟分布直方图
│       │   ├── demo-slow.sh                  #   慢操作捕获
│       │   ├── demo-normal.sh                #   JSON 监控输出
│       │   └── demo-stress.sh                #   db_bench 压力测试
│       └── case/                             # 案例研究
│           ├── start-ckb.sh                  #   启动 CKB 工具
│           ├── case-1-ibd-write-pattern.sh   #   IBD 写入模式
│           └── case-2-compaction-storm.sh    #   Compaction storm
│
└── README.md / README_zh.md                  # 项目 README
```

---

## 8. 故障排查

### ckb-probe 启动失败

```bash
# 检查 eBPF 二进制是否存在
ls -la ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf

# 重新构建
cargo xtask build-ebpf && cargo build --release
```

### 找不到 RocksDB 符号

```bash
# 验证 CKB 二进制中的 RocksDB 符号
ckb-probe symbols /path/to/ckb --tier 1
```

### P-4 结果不稳定

节点接近 tip 时 blocks/min 波动大，这是预期行为。让 CKB 停机几小时落后于 tip 后再测试：

```bash
# 停 CKB 几小时，重启后运行测试
./docker/scripts/perf/perf-run-orchestrator.sh
```

### Docker 中 BPF 权限不足

确保使用 `--privileged` 并挂载：
```bash
-v /sys/kernel/debug:/sys/kernel/debug:ro
-v /sys/kernel/btf:/sys/kernel/btf:ro
```

### Docker 中 uprobe 采集不到数据（QPS 全为 0）

原因：uprobe 通过 binary 路径 attach。容器内默认用 `/usr/local/bin/ckb`，但宿主机进程的 exe 是 `/root/ckb`，路径不匹配导致 hook 失败。

解决：挂载宿主机 CKB binary 并保持路径一致：
```bash
-v /root/ckb:/root/ckb:ro -e CKB_BIN=/root/ckb
```

### Docker 构建失败：无法拉镜像

Docker daemon 默认不继承 shell 环境变量中的代理。需要单独配置，详见 [5.1 节](#51-前提docker-代理配置)。

### Docker 构建失败：GLIBC 版本不匹配

编译阶段的 Rust 基础镜像 glibc 版本可能高于运行时镜像。确保运行时 stage 使用 `ubuntu:24.04`（glibc 2.39）而非 `debian:bookworm-slim`（glibc 2.36）。

### 48h 测试中途被中断

数据文件是增量写入的，已采集的数据不会丢失：

```bash
# 用已有数据生成部分报告
./docker/scripts/stability/generate-report.sh /tmp/stability-<timestamp>/
```
