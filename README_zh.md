# ckb-probe

基于 eBPF 的 CKB 全节点深度可观测性工具。

[English](README.md)

## 项目简介

ckb-probe 通过 eBPF（uprobe / kprobe / tracepoint）为 CKB 全节点提供应用语义级的实时性能洞察——无需修改 CKB 源码。输出"RocksDB GET 耗时 23μs，读取 512 字节"而非"pwrite64 系统调用"。

## 功能特性

- **五种 RocksDB 操作追踪**：GET、PUT、WRITE、ITER_NEW、TXN_COMMIT，通过 uprobe/uretprobe
- **实时指标**：每操作 QPS、Avg/P50/P99 延迟、Bytes/s
- **四种显示模式**：默认表格 / 直方图 / 慢操作 / JSON
- **EWMA 异常检测**：基线学习 + 5 倍尖峰告警 + 绝对 P99 上限
- **进程重启恢复**：自动检测 CKB 退出并重新 attach 到新 PID（S-4）
- **低开销**：+1.29% CPU、22.9 MB RSS、13K events/sec 零丢失
- **三级符号分析**：分析 CKB 二进制符号的 uprobe 可用性
- **eBPF 探针验证**：验证 uprobe/kprobe/tracepoint + 实时事件采集
- **Docker 可复现环境**：单容器包含所有工具和脚本

## 子命令

| 命令 | 说明 |
|------|------|
| `check` | 环境验证 + eBPF 探针验证 + 实时事件采集 |
| `symbols` | ELF 符号分析，三级分类 |
| `rocksdb` | RocksDB 实时监控（表格 / 直方图 / 慢操作 / JSON） |

## 快速开始

### 前置条件

- Linux 内核 ≥ 5.8，支持 BTF（`/sys/kernel/btf/vmlinux`）
- Root 或 CAP_BPF + CAP_SYS_ADMIN
- CKB testnet 节点及数据目录
- **仅限 testnet，永远不要在 mainnet 上使用**

有两种使用方式：**手动编译**（直接在宿主机运行）或 **Docker**（推荐，环境可复现）。

---

### 方式一：手动编译运行

#### 1. 安装依赖

```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y \
    clang llvm libelf-dev zlib1g-dev pkg-config \
    curl build-essential

# 安装 Rust（如未安装）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# 安装 nightly 工具链和 BPF linker
rustup install nightly
rustup component add rust-src --toolchain nightly
cargo install bpf-linker --locked
```

#### 2. Clone 并编译

```bash
git clone https://github.com/<org>/ckb-probe.git
cd ckb-probe

# 编译 eBPF 程序（需要 nightly）
cargo xtask build-ebpf --release

# 编译用户态程序
cargo build --release -p ckb-probe
```

编译产物：
- 用户态：`target/release/ckb-probe`
- eBPF：`ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf`

#### 3. 运行

```bash
# 确认 CKB 正在运行
CKB_PID=$(pgrep -x ckb)
CKB_BIN=$(readlink /proc/$CKB_PID/exe)

# 环境检查 + eBPF 探针验证
sudo ./target/release/ckb-probe check --binary $CKB_BIN

# ELF 符号分析
sudo ./target/release/ckb-probe symbols --binary $CKB_BIN

# RocksDB 实时监控（表格模式）
sudo ./target/release/ckb-probe rocksdb --binary $CKB_BIN --pid $CKB_PID

# 直方图模式
sudo ./target/release/ckb-probe rocksdb --binary $CKB_BIN --pid $CKB_PID --histogram

# 慢操作捕获（阈值 1ms）
sudo ./target/release/ckb-probe rocksdb --binary $CKB_BIN --pid $CKB_PID --slow --threshold 1000

# JSON 输出
sudo ./target/release/ckb-probe rocksdb --binary $CKB_BIN --pid $CKB_PID --json
```

> **注意：** 运行 ckb-probe 时，当前工作目录必须包含 `ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf`（即项目根目录），否则会找不到 eBPF 程序。

---

### 方式二：Docker 运行（推荐）

#### 1. 构建 Docker 镜像

```bash
git clone https://github.com/<org>/ckb-probe.git
cd ckb-probe
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

构建约 10-15 分钟，两阶段镜像（约 100 MB）包含 ckb-probe、db_bench 及全部脚本。CKB binary **不打包进镜像**，运行时通过 bind mount 挂载宿主机 binary（见第 3 步）——uprobe 必须按宿主机 CKB 进程的 exe 路径挂载才能生效。

### 2. 准备 CKB 节点

将 CKB testnet 节点数据放到宿主机上：

```
/root/ckb-testnet/
├── ckb              # CKB 可执行文件
├── ckb.toml         # 配置文件
└── data/            # 链数据（含 db/ 子目录）
```

启动 CKB：

```bash
cd /root/ckb-testnet && ./ckb run &
```

### 3. Docker 运行命令模板

所有脚本通过以下模板运行：

```bash
DOCKER_RUN="docker run --rm --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest"
```

> **关键：** `-v` 挂载 CKB binary 的路径必须与宿主机进程 exe 路径完全一致，否则 uprobe 无法 attach，采集不到数据。用 `readlink /proc/$(pgrep -x ckb)/exe` 确认。

### 4. 运行演示脚本

```bash
$DOCKER_RUN demo-check             # 环境 + 符号检查            (< 30s)
$DOCKER_RUN demo-table 60          # 默认表格模式               (60s)
$DOCKER_RUN demo-histogram 60      # 延迟分布直方图             (60s)
$DOCKER_RUN demo-slow 60 1000      # 慢操作捕获（阈值 1ms）     (60s)
$DOCKER_RUN demo-normal 60         # JSON 监控输出              (60s)
$DOCKER_RUN demo-stress 100000     # db_bench 压力 + 异常检测   (2-3 min)
```

### 5. 运行性能测试（P-1 ~ P-4）

CKB 节点需要**落后于网络 tip**（IBD 状态），才有足够的 RocksDB 操作密度。使用停机过几小时/几天的节点数据。

```bash
# 完整 4h 测试（Phase A with-probe + Phase B baseline）
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
tail -5 /tmp/perf-run/progress.log

# 查看报告
cat /tmp/perf-run/REPORT.txt
```

严格 P-4 对比（两个 phase 都在 IBD 状态），单独跑 Phase A 和 Phase B：

```bash
# Phase A（with-probe）：停 CKB，解压全新数据，然后：
./docker/scripts/perf/perf-phase-a.sh /root/ckb-testnet

# Phase B（baseline）：停 CKB，再次解压全新数据，然后：
./docker/scripts/perf/perf-phase-b.sh /root/ckb-testnet
```

### 6. 运行案例研究

```bash
# IBD 写入模式分析（CKB 需在 IBD 状态）
$DOCKER_RUN case-1 3600

# Compaction storm 捕获（自动应用 aggressive 配置，结束后自动恢复）
$DOCKER_RUN case-2 1800
```

### 7. 运行 48h 稳定性测试（S-1 ~ S-4）

```bash
docker run -d --name stability-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest stability

# 缩短时间快速验证
docker run -d --name stability-test \
  ... \
  -e DURATION_HOURS=2 \
  ckb-probe:latest stability
```

测试内容：S-1（48h 无崩溃）、S-2（RSS 增长 ≤ 5 MB）、S-3（无 BPF dmesg 警告）、S-4（T+24h 自动重启 CKB，验证 probe 重连）。

### 8. 交互式 shell

```bash
docker run --rm -it --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  --entrypoint "" \
  ckb-probe:latest bash
```

## 性能测试结果（P-1 ~ P-4）

在 CKB testnet 真实 IBD 工作负载下测试（Docker 容器，24 核 Linux 6.8，CKB v0.204.0）：

| 指标 | 结果 | 预算 | 状态 |
|------|------|------|------|
| P-1 CPU 附加开销 | +1.29%（相对值） | ≤ 3% | ✅ PASS |
| P-2 RSS 内存 | 22.89 MB（稳定无增长） | ≤ 50 MB | ✅ PASS |
| P-3 BPF 事件丢失 | 0 / 2000 万事件（0.0000%），峰值 13K/s | < 0.1% | ✅ PASS |
| P-4 同步退化 | -0.86%（无退化） | < 1% | ✅ PASS |

## Docker 命令一览

| 命令 | 说明 | 耗时 |
|------|------|------|
| **演示** | | |
| `demo-check` | 环境 + 符号检查 + eBPF 验证 | < 30s |
| `demo-table [秒]` | 默认表格模式 | 60s |
| `demo-histogram [秒]` | 延迟分布直方图 | 60s |
| `demo-slow [秒] [μs]` | 慢操作捕获 | 60s |
| `demo-normal [秒]` | JSON 监控输出 | 5 min |
| `demo-stress [条目数]` | db_bench 压力 + 异常检测 | 2-3 min |
| **性能测试** | | |
| `perf` | P-1~P-4 全量评估 | ~4h |
| `p3-stress [秒]` | 单项 P-3 事件丢失测试 | 5 min |
| **稳定性测试** | | |
| `stability` | S-1~S-4 48h 稳定性测试 | 48h |
| `stability-report [目录]` | 生成稳定性报告 | 即时 |
| **案例研究** | | |
| `case-1 [秒]` | IBD 写入模式分析 | ~2h |
| `case-2 [秒]` | Compaction storm 捕获 | ~30 min |
| **工具** | | |
| `bash` | 交互式 shell | - |
| `start-ckb` | 启动容器内 CKB | - |
| `help` | 显示用法 | - |

## RocksDB 操作追踪

| 操作 | RocksDB 函数 | Bytes/s 来源 |
|------|-------------|-------------|
| GET | `rocksdb_get_pinned_cf` | uretprobe 读取 PinnableSlice 大小 |
| PUT | `rocksdb_transaction_put_cf` | entry probe 从 arg(5) 读取 vlen |
| WRITE | `rocksdb_write` | — (WriteBatch 内部) |
| ITER_NEW | `rocksdb_create_iterator_cf` | — (无 payload) |
| TXN_COMMIT | `rocksdb_transaction_commit` | 每线程 PUT 累加器 |

## 项目结构

```
ckb-probe/
├── ckb-probe/                  # 用户态 CLI（Rust + tokio）
│   └── src/commands/
│       ├── check.rs            # 环境检测 + eBPF 验证
│       ├── symbols.rs          # ELF 符号分析
│       └── rocksdb.rs          # RocksDB 监控 + 异常检测 + S-4 重连
├── ckb-probe-ebpf/             # eBPF 内核态程序（#![no_std]）
│   └── src/main.rs             # uprobe/kprobe/tracepoint BPF 程序
├── ckb-probe-common/           # 共享类型定义
├── docker/                     # Docker + 全部脚本
│   ├── Dockerfile              # 两阶段构建（rust builder + ubuntu runtime）
│   ├── entrypoint.sh           # 命令分发器
│   ├── env-check.sh            # 宿主机前置检查
│   └── scripts/
│       ├── perf/               # P-1~P-4 性能测试脚本
│       ├── stability/          # S-1~S-4 稳定性测试 + 报告生成器
│       ├── demo/               # 6 个演示脚本
│       └── case/               # 2 个案例研究脚本
├── docs/                       # 文档（EN + 中文）
└── .github/workflows/ci.yml    # CI：编译 + lint + 脚本检查
```

## 文档

| 文档 | EN | 中文 |
|------|-----|------|
| 从零开始使用指南 | [EN](docs/getting-started_en.md) | [中文](docs/getting-started_zh.md) |
| Docker 快速入门 | [EN](docs/docker-quickstart.md) | [中文](docs/docker-quickstart_zh.md) |
| 技术深度分析 | [EN](docs/technical-deep-dive_en.md) | [中文](docs/technical-deep-dive_zh.md) |
| 代码架构 | [EN](docs/code-architecture.md) | [中文](docs/code-architecture_zh.md) |
| 演示流程 | [EN](docs/demo-walkthrough_en.md) | [中文](docs/demo-walkthrough_zh.md) |
| 测试基础设施指南 | [EN](docs/test-infrastructure_en.md) | [中文](docs/test-infrastructure_zh.md) |
| 稳定性报告 | [EN](docs/STABILITY-REPORT.md) | [中文](docs/STABILITY-REPORT_zh.md) |
| 案例研究报告 | — | [中文](docs/CASE-STUDY-REPORT_zh.md) |
| 结项报告 | [EN](docs/final-report_en.md) | [中文](docs/final-report_zh.md) |
| 月度报告（最终） | [EN](docs/monthly-report-final_en.md) | [中文](docs/monthly-report-final_zh.md) |
| Release Notes v0.1.0 | [EN](docs/RELEASE-v0.1.0.md) | — |

## 验收清单

### 功能验证（F-1 ~ F-10）

| # | 要求 | 状态 |
|---|------|------|
| F-1 | `check` 报告内核/BTF/BPF 并提供可操作提示 | ✅ |
| F-2 | `symbols` 生成 Tier 1/2/3 报告 + RocksDB 链接方式检测 | ✅ |
| F-3 | `rocksdb --pid` 以 1s 间隔输出实时统计表格 | ✅ |
| F-4 | 五种操作（GET/PUT/WRITE/ITER_NEW/TXN_COMMIT）追踪 QPS/avg/P50/P99/bytes | ✅ |
| F-5 | `--slow --threshold` 捕获单个慢操作 | ✅ |
| F-6 | `--histogram` 显示 log2 分桶延迟分布 | ✅ |
| F-7 | EWMA 异常检测在合成延迟飙升后 15s 内触发告警 | ✅ |
| F-8 | `--json` 输出有效 JSON，jq 可解析 | ✅ |
| F-9 | SIGINT/SIGTERM 优雅关闭，BPF 干净卸载 | ✅ |
| F-10 | CKB 退出时优雅处理 + 重启后自动重连 | ✅ |

### 性能开销（P-1 ~ P-4）

| # | 要求 | 结果 | 状态 |
|---|------|------|------|
| P-1 | CPU 附加 ≤ 3%（相对值） | +1.29% | ✅ |
| P-2 | RSS ≤ 50 MB | 22.89 MB | ✅ |
| P-3 | BPF 事件丢失 < 0.1%（10K+/s） | 0.0000%，峰值 13K/s | ✅ |
| P-4 | 同步退化 < 1% | -0.86% | ✅ |

### 稳定性（S-1 ~ S-4）

| # | 要求 | 状态 |
|---|------|------|
| S-1 | 48h 无崩溃/panic | 脚本就绪 |
| S-2 | RSS 增长 ≤ 5 MB | 脚本就绪 |
| S-3 | 无 BPF dmesg 警告 | 脚本就绪 |
| S-4 | CKB 重启后自动重连 | ✅ 已验证 |

## 镜像导出

```bash
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz
docker load < ckb-probe-latest.tar.gz   # 另一台机器导入
```

## 许可证

MIT OR Apache-2.0
