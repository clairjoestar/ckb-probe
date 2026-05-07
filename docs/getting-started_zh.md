# ckb-probe 从零开始使用指南

> 从 clone 仓库到运行所有测试和演示的完整步骤。
>
> **范围：仅 CKB testnet，永远不涉及 mainnet。**

---

## 1. 前置条件

| 要求 | 最低版本 |
|------|----------|
| Linux 内核 | ≥ 5.8 |
| BTF 支持 | `/sys/kernel/btf/vmlinux` 存在 |
| Docker | ≥ 20.10 |
| 可用内存 | ≥ 4 GB |
| 可用磁盘 | ≥ 20 GB（不含 CKB 数据） |
| CKB testnet 节点数据 | 已同步的 data 目录 |
| CKB binary | 与数据匹配的 ckb 可执行文件 |

---

## 2. Clone 仓库

```bash
git clone https://github.com/<org>/ckb-probe.git
cd ckb-probe
```

---

## 3. 构建 Docker 镜像

```bash
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

构建约 10-15 分钟。镜像包含：
- ckb-probe（从源码编译，含 eBPF）
- db_bench（从 RocksDB 源码编译）
- 全部测试 / 演示 / 案例脚本

**注意：** CKB binary 不包含在镜像中，需通过 `-v` 从宿主机挂载。

---

## 4. 准备 CKB 节点

将已有的 CKB testnet 节点数据放到宿主机上，例如 `/root/ckb-testnet/`：

```
/root/ckb-testnet/
├── ckb              # CKB binary
├── ckb.toml         # 配置文件
├── ckb-miner.toml
├── default.db-options
└── data/            # 链数据（含 db/ 子目录）
```

启动 CKB 节点：

```bash
cd /root/ckb-testnet
./ckb run &

# 验证 RPC 可用
curl -s -X POST http://127.0.0.1:8124 \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' | jq
```

---

## 5. Docker 运行命令模板

所有脚本都通过以下模板在 Docker 内运行：

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

**参数说明：**

| 参数 | 用途 |
|------|------|
| `--privileged --pid host` | eBPF 需要特权 + 共享宿主机 PID namespace |
| `--network host` | 容器直接使用宿主机网络（访问 CKB RPC） |
| `-v .../ckb:...ckb:ro` | 挂载 CKB binary（路径必须与宿主机进程 exe 一致） |
| `-e CKB_BIN=...` | 告诉脚本 CKB binary 路径 |

> **关键：** `-v` 挂载的 CKB binary 路径必须和宿主机上 CKB 进程的 exe 路径完全一致，
> 否则 uprobe 无法 attach，采集不到数据。用 `readlink /proc/$(pgrep -x ckb)/exe` 确认。

---

## 6. 运行演示脚本

演示脚本只读监控，不影响 CKB 节点，随时可以跑。

### 6.1 环境检查

```bash
$DOCKER_RUN demo-check
```

验证内核、BTF、BPF、CKB 进程、RocksDB 符号，约 30 秒。

### 6.2 默认表格模式

```bash
$DOCKER_RUN demo-table 60       # 60 秒
```

展示实时 QPS / Avg / P50 / P99 / Bytes/s 表格。

### 6.3 延迟分布直方图

```bash
$DOCKER_RUN demo-histogram 60   # 60 秒
```

展示五种 RocksDB 操作的 log2 分桶延迟分布。

### 6.4 慢操作捕获

```bash
$DOCKER_RUN demo-slow 60 1000   # 60 秒，阈值 1000μs
```

捕获超过阈值的 RocksDB 操作，显示时间戳 / 操作类型 / 延迟 / 大小。

### 6.5 JSON 监控输出

```bash
$DOCKER_RUN demo-normal 60      # 60 秒
```

输出机器可读的 JSON 格式监控数据。

### 6.6 压力测试（需要 db_bench）

```bash
$DOCKER_RUN demo-stress 100000  # 10 万条 fillrandom
```

使用 db_bench 注入 RocksDB 负载，观察 ckb-probe 捕获延迟飙升和慢操作。

---

## 7. 运行性能测试 (P-1 ~ P-4)

### 7.1 前提

CKB 节点需要**落后于网络 tip**（处于 IBD 状态），这样才有足够的 RocksDB 操作密度。

方法：
- 使用一份停机过几小时/几天的节点数据
- 或停止 CKB 几小时后重启

### 7.2 全量 4 小时测试

```bash
docker run -d --name perf-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest perf
```

Phase A (2h with-probe) → Phase B (2h baseline) → 自动出报告。

### 7.3 监控进度

```bash
# 进度
tail -5 /tmp/perf-run/progress.log

# P-2 RSS
tail -1 /tmp/perf-run/p2-rss.log | awk '{printf "RSS: %.1f MB\n", $2/1024}'

# P-3 事件丢失
grep -a "BPF event loss" /tmp/perf-run/probe-slow.log | tail -1

# P-4 同步
tail -3 /tmp/perf-run/p4-with-probe.log

# 最终报告
cat /tmp/perf-run/REPORT.txt
```

### 7.4 单项测试

不想跑完整 4h，可以进入容器单独跑：

```bash
# 进入容器
docker run --rm -it --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  --entrypoint "" \
  ckb-probe:latest bash

# 在容器内执行：
/opt/scripts/perf/p1-cpu.sh baseline 60       # P-1 baseline 1 分钟
/opt/scripts/perf/p1-cpu.sh with-probe 60     # P-1 with-probe（需要先启动 ckb-probe）
/opt/scripts/perf/p2-rss.sh                   # P-2 RSS 监控
/opt/scripts/perf/p3-stress.sh 300            # P-3 事件丢失 5 分钟
/opt/scripts/perf/p4-sync.sh baseline 5       # P-4 baseline 5 分钟

# P-3 极端压测：--threshold 设置慢操作阈值，单位微秒（μs）。
# 只有延迟超过此阈值的操作才会从内核通过 RingBuf 发到用户态。
#
# --threshold 1000（默认，1ms）：只捕获真正的慢操作
#   （例如 GET 从正常的 10μs 飙升到 5ms，可能是 compaction 或 cache miss）。
#   事件量少，CPU 开销低。日常监控和性能测试使用。
#
# --threshold 1（1μs）：几乎所有 RocksDB 操作延迟都超过 1μs，
#   等于没有过滤——全部操作变成"事件"发送到用户态。
#   IBD 期间高达 10K+ events/sec。这些正常操作（5-50μs）本身不慢，
#   没有诊断价值，唯一目的是压测 P-3 BPF 事件丢失率的极限。
#   使用 RingBuf 替代 PerfEventArray，消除了逐事件上下文切换，
#   大幅降低 CPU 开销。
ckb-probe rocksdb --binary $CKB_BIN --pid $(pgrep -x ckb) \
    --slow --threshold 1 --interval 5
```

### 7.5 严格 P-4 对比测试

P-4 需要两个 phase 都在 IBD 状态下跑。如果 Phase A 跑完后节点追上 tip，Phase B 没有 IBD 工作量，对比无意义。

解决方案：Phase B 单独用一份全新解压的节点数据跑。

```bash
# Phase A 跑完后，停 CKB，重新解压数据
pkill -x ckb
rm -rf /root/ckb-testnet
unzip -o /root/ckb-testnet.zip -d /root/ckb-testnet
cd /root/ckb-testnet && ./ckb run &

# 单独跑 Phase B baseline
docker run -d --name perf-baseline \
  --privileged --pid host --network host \
  --entrypoint "" \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest bash -c \
  "pidstat -u -h -p \$(pgrep -x ckb) 5 1440 > /tmp/perf-run/p1-baseline.log 2>&1"
  # 同时跑 P-4 tip sampler（参考 perf-run-orchestrator.sh 的 Phase B 逻辑）
```

---

## 8. 运行案例研究

### 8.1 Case 1: IBD 写入模式分析

```bash
$DOCKER_RUN case-1 3600          # 最长等 1 小时
```

CKB 需要在 IBD 状态。观察 PUT/WRITE 吞吐量和延迟随链高度增长的演变。

### 8.2 Case 2: Compaction Storm 捕获

```bash
$DOCKER_RUN case-2 1800          # 最长等 30 分钟
```

自动应用 `ckb.toml.aggressive` 降低 compaction 触发阈值，等待 ANOMALY DETECTED 事件，捕获延迟飙升的 before/during/after 上下文。脚本结束后自动恢复原始配置。

---

## 9. 运行 48h 稳定性测试 (S-1 ~ S-4)

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
```

测试内容：
- **S-1**：48h 无崩溃/panic/重启
- **S-2**：RSS 增长 ≤ 5 MB
- **S-3**：dmesg 无 BPF 警告
- **S-4**：T+24h 自动重启 CKB，验证 probe 重连

### 9.1 缩短测试时间

```bash
# 2 小时快速验证
docker run -d --name stability-test \
  ... \
  -e DURATION_HOURS=2 \
  ckb-probe:latest stability
```

### 9.2 生成报告

```bash
# 测试完成后自动生成，或手动重新生成
$DOCKER_RUN stability-report /tmp/perf-run/stability-<timestamp>/
```

---

## 10. 查看输出

所有输出写到 `/tmp/perf-run/`（通过 bind mount 宿主机可直接访问）：

```bash
# 性能测试报告
cat /tmp/perf-run/REPORT.txt

# 稳定性测试报告
cat /tmp/perf-run/stability-*/STABILITY-REPORT.md

# 演示输出
ls /tmp/perf-run/demo/

# 案例研究报告
cat /tmp/perf-run/case1/REPORT.txt
cat /tmp/perf-run/case2/REPORT.txt
```

---

## 11. 运行顺序建议

```
1. docker build                    # 构建镜像 (~15 min)
2. 启动 CKB 节点
3. demo-check                      # 验证环境 (~30s)
4. demo-table / demo-histogram     # 快速演示 (~1 min each)
5. demo-slow                       # 慢操作演示 (~1 min)
6. demo-normal                     # JSON 输出 (~5 min)
7. demo-stress                     # 压力测试 (~3 min)
8. case-1                          # IBD 写入模式 (~30 min, 需要 IBD 状态)
9. case-2                          # Compaction storm (~30 min)
10. perf                           # P-1~P-4 全量测试 (~4h, 需要 IBD 状态)
11. stability                      # S-1~S-4 稳定性测试 (48h)
```

**注意：**
- 同一时间只能运行一个 ckb-probe 实例
- 步骤 8/10 需要 CKB 在 IBD 状态（节点数据落后于网络 tip）
- 步骤 10 的 Phase B 如需严格 P-4 对比，需要重新解压节点数据
- 步骤 11 耗时 48 小时，建议最后跑

---

## 12. 镜像导出

```bash
# 导出
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz

# 另一台机器导入
docker load < ckb-probe-latest.tar.gz
```
