# ckb-probe 结项报告（Week 5-8）

> 作者：Clair
> 周期：2026-04-13 ~ 2026-05-07
> 项目：ckb-probe — 基于 eBPF 的 CKB 全节点深度可观测性工具
> 仓库：https://github.com/clairjoestar/ckb-probe
> 许可证：MIT OR Apache-2.0
> 范围：仅限 CKB 测试网

---

## 一、项目总览

ckb-probe 是一个基于 eBPF（uprobe / kprobe / tracepoint）的 CKB 全节点深度可观测性工具，能够在不修改 CKB 源码、不重启节点的前提下，实时追踪 RocksDB 操作延迟、吞吐量和异常模式。

本报告为第二次（最终）月度社区分享报告，覆盖 Week 5-8 的工作。第一次月度报告（中期报告）覆盖了 Week 2-4。

---

## 二、里程碑完成状态

| 里程碑 | 原定时间 | 实际完成 | 状态 |
|--------|----------|----------|------|
| M1：eBPF 可行性验证 | Week 3 | Week 3 | ✅ 按期达成 |
| M2：`rocksdb` 子命令 + EWMA | Week 5 | Week 4 | ✅ 提前 1 周 |
| M3：完整发布 + 全部交付物 | Week 8 | Week 8 | ✅ 按期达成 |

**三个里程碑全部达成。**

---

## 三、Week 5-8 各周进展

### Week 5（Apr 13-19）：性能优化 + Docker 环境

| 交付项 | 说明 |
|--------|------|
| 内存优化 | RSS 87.9 MB → 21.9 MB（RingBuf 替代 PerfEventArray） |
| Docker 环境 | 两阶段 Dockerfile + 6 个演示脚本 + env-check.sh |
| S-4 进程重启恢复 | 自动检测 CKB 退出 + 轮询新 PID + 重连 |
| P-1~P-4 性能测试 | 全部 PASS |
| CI 流水线 | build + lint + script check + 每周 CKB 兼容检查 |

### Week 6（Apr 20-26）：48h 稳定性测试 + 案例研究

| 交付项 | 说明 |
|--------|------|
| S-1~S-4 稳定性测试 | 全部 PASS（48h 连续运行，RSS +0.00 MB，1s 重连） |
| Case 1：IBD 写入模式 | 22 分钟，109.7 GET QPS，6 个 ITER_NEW 异常 |
| Case 2：压缩风暴捕获 | GET 延迟 35x 飙升，6,112 个慢操作，0 丢失 |

### Week 7（Apr 27 - May 3）：JSON 优化 + 演示文档

| 交付项 | 说明 |
|--------|------|
| JSON --histogram 融合 | `--json --histogram` 联用时 JSON 包含 log2 延迟分布 |
| 演示说明文档 | 五步演示流程 + 真实终端输出 + Docker 指南 |
| Clippy 修复 | `manual_checked_ops` 警告修复 |

### Week 8（May 4-7）：文档定稿 + 发布

| 交付项 | 说明 |
|--------|------|
| 中英双语文档 | 6 对文档全部更新至最新代码 |
| 演示文档英文版 | demo-walkthrough 英文版本 |
| v0.1.0 发布准备 | tag + release notes |
| 结项报告 | 全部交付物整理 |

---

## 四、性能测试结果

双次全新 IBD 对比测试（Docker 容器内，CKB 测试网）：

| 指标 | 结果 | 预算 | 状态 |
|------|------|------|------|
| P-1 附加 CPU | +1.29%（2h 综合） | ≤ 3% | ✅ PASS |
| P-2 常驻内存 | 22.89 MB（稳定无增长） | ≤ 50 MB | ✅ PASS |
| P-3 事件丢失 | 0 / 20,034,457 = 0.0000% | < 0.1% | ✅ PASS |
| P-4 同步退化 | -0.86%（2h 综合） | < 1% | ✅ PASS |

**四项性能指标全部 PASS。**

---

## 五、稳定性测试结果

48 小时连续运行（CKB 测试网，16,693 个时序采样点）：

| 指标 | 结果 | 说明 |
|------|------|------|
| S-1 无崩溃 | **PASS** | 48h 全程零 panic/SIGSEGV |
| S-2 内存稳定 | **PASS** | RSS 增长 0.00 MB（预算 5 MB） |
| S-3 无 BPF 错误 | **PASS** | 48h 零 BPF 子系统错误 |
| S-4 重启恢复 | **PASS** | CKB 重启后 1 秒重连 |

### 资源使用

| 指标 | 最小值 | 最大值 | 均值 | P99 |
|------|--------|--------|------|-----|
| Probe CPU% | 0.00 | 0.38 | 0.09 | 0.29 |
| Probe RSS | 21.4 MB | 21.4 MB | 21.4 MB | 21.4 MB |

---

## 六、案例研究

### Case 1：IBD 写入模式分析

| 项目 | 值 |
|------|-----|
| 持续时间 | 22 分钟 |
| 同步区块 | 197 |
| GET 平均 QPS | 109.7 |
| 异常事件 | 6（ITER_NEW P99 触发，compaction 争用） |

ckb-probe 完整捕获了 IBD 从追赶到稳态的全过程，GET 为主导操作，写入负载较轻。

### Case 2：压缩风暴捕获

| 项目 | 值 |
|------|-----|
| 持续时间 | 30 分钟 |
| GET 延迟飙升 | 正常 ~200us → 平均 6,988us（**35 倍**） |
| 慢操作总数 | 6,112（阈值 >1,000us） |
| BPF 事件丢失 | 0 / 6,112 = 0.0000% |

通过 aggressive RocksDB 参数注入压缩风暴，ckb-probe 成功捕获全部慢操作，零丢失。

---

## 七、技术亮点

### 7.1 内存优化：87.9 MB → 21.9 MB

| 优化项 | 修改前 | 修改后 |
|--------|--------|--------|
| SLOW_EVENTS 数据通道 | PerfEventArray（24 个 per-CPU ring buffer） | RingBuf（全 CPU 共享 256KB） |
| Perf buffer 大小 | 1024 pages/CPU (4MB) | 16 pages/CPU (64KB) |
| HashMap max_entries | 10240 | 1024 |

### 7.2 进程重启恢复（S-4）

```
Monitoring PID 3310428 → CKB 停止
⚠ Target process (PID 3310428) exited. Waiting for CKB to restart...
✅ CKB restarted (new PID 673651). Reattaching probes...
```

后台线程每秒检查 `/proc/{pid}`，CKB 退出后自动扫描同一 binary 的新进程，重新加载 BPF 程序并 reattach 所有 uprobe。

### 7.3 Docker 可复现环境

- 两阶段 Dockerfile：编译阶段 + 运行时阶段
- 6 个演示脚本：demo-check / demo-table / demo-histogram / demo-slow / demo-normal / demo-stress
- env-check.sh：6 项宿主机前置条件检查
- 一条命令即可运行完整演示

### 7.4 JSON --histogram 融合输出

```json
{
  "operations": {
    "GET": {
      "qps": 845,
      "avg_us": 24.97,
      "p50_us": 24.58,
      "p99_us": 98.30,
      "bytes_per_sec": 101976,
      "histogram": [
        { "ge_us": 4.1, "count": 1528 },
        { "ge_us": 16.38, "count": 727 }
      ]
    }
  }
}
```

---

## 八、代码统计

| 指标 | 值 |
|------|-----|
| Rust 代码 | ~4,187 行 |
| 提交数 | 31 |
| 子命令 | 3 个（check / symbols / rocksdb） |
| BPF 程序 | uprobe / uretprobe / kprobe / tracepoint |
| 输出模式 | 4 种（表格 / 直方图 / 慢操作 / JSON） |
| 文档 | 6 对中英双语文档 |
| 许可证 | MIT OR Apache-2.0 |

---

## 九、交付物清单

| 类别 | 交付物 |
|------|--------|
| 核心工具 | `ckb-probe` CLI（check / symbols / rocksdb） |
| eBPF 程序 | uprobe + uretprobe + kprobe + tracepoint |
| 异常检测 | EWMA 基线 + 三路触发 + 四项安全特性 |
| Docker | Dockerfile + 6 演示脚本 + env-check.sh |
| 性能验证 | P-1~P-4 全部 PASS |
| 稳定性验证 | S-1~S-4 全部 PASS（48h） |
| 案例研究 | IBD 写入模式 + 压缩风暴捕获 |
| CI | build + lint + script check + CKB 兼容检查 |
| 文档 | 6 对中英双语文档 + 演示说明 |

---

## 十、未来计划

ckb-probe v0.1.0 已覆盖 RocksDB 层的完整可观测性。后续版本计划扩展到更多维度：

| 方向 | 说明 |
|------|------|
| P2P 网络子命令 | 通过 kprobe 追踪 CKB P2P 消息延迟和吞吐 |
| Syscall 子命令 | tracepoint 采集系统调用分布和延迟 |
| TUI 仪表盘 | 基于 ratatui 的交互式终端界面 |
| Prometheus 导出器 | 标准指标端点，对接 Grafana 可视化 |

---

## 致谢

感谢 CKB 社区和 Nervos 资助计划的支持。ckb-probe 的目标是为 CKB 测试网节点运维提供生产级的深度可观测性工具，帮助运维人员快速定位性能瓶颈和异常模式。

欢迎试用和反馈：https://github.com/clairjoestar/ckb-probe

---

*相关文档：[稳定性报告](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/STABILITY-REPORT_zh.md) · [案例研究](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/CASE-STUDY-REPORT_zh.md) · [演示说明](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/demo-walkthrough_zh.md) · [结项报告](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/final-report_zh.md)*
