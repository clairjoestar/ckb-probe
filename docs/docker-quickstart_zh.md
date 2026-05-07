# ckb-probe Docker 快速入门

基于 eBPF 的 CKB testnet 节点深度可观测性工具。

## 构建

```bash
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

镜像包含 ckb-probe、db_bench 及全部脚本。CKB binary 不包含在镜像内，需通过 `-v` 从宿主机挂载。CKB 数据同样通过 bind mount 挂载。

## 快速开始（监控宿主机 CKB）

```bash
docker run --rm --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest demo-check
```

**关键：** 挂载的 CKB binary 路径必须与宿主机进程 exe 路径完全一致，否则 uprobe 无法 attach。

## 命令一览

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
| `perf` | P-1~P-4 全量评估（CKB 需落后于 tip） | ~4h |
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

## 镜像导出

```bash
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz
```

仅限 testnet，永远不要在 mainnet 上使用。
