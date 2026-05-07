# ckb-probe 结项报告

> **项目范围：仅限 CKB 测试网**
>
> 项目周期：2026-03-23 ~ 2026-05-07（8 周）
> 作者：Clair
> 预算：1,000 USD

---

## 1. 项目概述

ckb-probe 是基于 eBPF 的 CKB 全节点深度可观测性工具。通过 uprobe/kprobe/tracepoint 等内核态探针，以零侵入方式实时捕获 CKB 测试网节点的 RocksDB 存储层、网络层和系统调用行为，提供延迟分布、异常检测、慢操作告警等运维洞察。

**核心特性：**
- 零代码修改：无需重编译 CKB，直接挂载到运行中的节点
- 低开销：CPU 增量 <1.3%，RSS 稳定在 22.89 MB
- 零事件丢失：48 小时测试中 20,034,457 个事件 0 丢失
- 自动重连：CKB 重启后 1 秒内自动恢复探针

**技术栈：** Rust + Aya（eBPF 框架）+ libbpf + RocksDB C API uprobe

---

## 2. 交付物清单

| # | 交付物 | 说明 | 状态 |
|---|--------|------|------|
| D-1 | **ckb-probe CLI v0.1.0** | 3 个子命令：check / symbols / rocksdb | ✅ 完成 |
| D-2 | **ckb-probe-ebpf BPF 程序** | 8 组 uprobe + 2 组 kprobe + 1 tracepoint = 21 个 BPF 程序 | ✅ 完成 |
| D-3 | **Docker 环境** | 两阶段 Dockerfile，6 个 demo 脚本，性能/稳定性/案例分析脚本 | ✅ 完成 |
| D-4 | **48 小时稳定性测试** | S-1\~S-4 全部 PASS | ✅ 完成 |
| D-5 | **性能测试** | P-1\~P-4 全部 PASS | ✅ 完成 |
| D-6 | **案例分析** | IBD 写入模式 + compaction 风暴 | ✅ 完成 |
| D-7 | **双语文档** | 6 对文档（EN/ZH）：架构、演示、快速开始、入门、技术深入、测试基础设施 | ✅ 完成 |
| D-8 | **CI/CD** | build + lint + 脚本检查 + 每周 CKB 兼容性检查 | ✅ 完成 |

### D-1 子命令详情

| 子命令 | 功能 |
|--------|------|
| `check` | 8 项环境检测 + eBPF 探针验证 + 3 秒实时事件采集 |
| `symbols` | 三级 ELF 符号分类（20 Tier 1 / 21 Tier 2 / 12 Tier 3） |
| `rocksdb` | 5 种操作（GET/PUT/WRITE/ITER\_NEW/TXN\_COMMIT），4 种输出模式（table/histogram/slow/JSON），EWMA 异常检测，S-4 自动重连 |

---

## 3. 验收标准对照

### 3.1 功能验收（F-1 ~ F-10）

| 编号 | 标准 | 结果 | 备注 |
|------|------|------|------|
| F-1 | check 报告内核/BTF/BPF/权限/CKB 并给出修复提示 | ✅ PASS | |
| F-2 | symbols 生成 Tier 1/2/3 报告，含 RocksDB 链接检测 | ✅ PASS | |
| F-3 | rocksdb 输出 1 秒间隔表格 | ✅ PASS | |
| F-4 | 追踪 5 种操作 | ✅ PASS | 偏差：ITER\_NEW/TXN\_COMMIT 替代 DELETE/ITER\_SEEK（见 §7） |
| F-5 | --slow --threshold 捕获超阈值操作 | ✅ PASS | |
| F-6 | --histogram 显示 log2 分布 | ✅ PASS | |
| F-7 | EWMA 异常检测触发 | ✅ PASS | 300 秒预热，case-2 中验证 |
| F-8 | --json 输出可被 jq 解析的有效 JSON | ✅ PASS | |
| F-9 | SIGINT/SIGTERM 优雅退出，BPF 程序卸载 | ✅ PASS | |
| F-10 | CKB 退出后优雅处理 + 自动重连 | ✅ PASS | S-4 验证 |

### 3.2 性能验收（P-1 ~ P-4）

| 编号 | 指标 | 预算 | 实测值 | 结果 |
|------|------|------|--------|------|
| P-1 | CPU 增量 | ≤3% | +1.29% | ✅ PASS |
| P-2 | RSS 内存 | ≤50 MB | 22.89 MB | ✅ PASS |
| P-3 | 事件丢失率 | <0.1% | 0/20,034,457 = 0.0000% | ✅ PASS |
| P-4 | 同步降级 | <1% | -0.86% | ✅ PASS |

### 3.3 稳定性验收（S-1 ~ S-4）

| 编号 | 指标 | 预算 | 实测值 | 结果 |
|------|------|------|--------|------|
| S-1 | 48 小时无崩溃 | 0 crash | 0 crash | ✅ PASS |
| S-2 | RSS 增长 | ≤5 MB | 0.00 MB | ✅ PASS |
| S-3 | BPF dmesg 错误 | 0 | 0 | ✅ PASS |
| S-4 | CKB 重启后重连 | <5s | 1s | ✅ PASS |

---

## 4. 技术亮点

### 4.1 三级符号分类体系

对 CKB 二进制中的 ELF 符号进行三级分类，确定最稳定的探针挂载点：

- **Tier 1**（RocksDB C API，`extern "C"`）：跨版本稳定，理想 uprobe 目标
- **Tier 2**（Rust 跨 crate 公开函数）：hash 后缀每次编译不同，需模糊匹配
- **Tier 3**（内联/LTO 消除）：release 构建中不可用

### 4.2 EWMA 异常检测

采用指数加权移动平均（EWMA）算法实时检测延迟异常。300 秒预热期建立基线后，当单次操作延迟超过 EWMA 均值 + 3 倍标准差时触发告警。在 case-2（compaction 风暴）中成功捕获异常。

### 4.3 S-4 自动重连

当 CKB 进程退出时，ckb-probe 优雅释放 BPF 资源并进入监听模式。检测到 CKB 重新启动后，在 1 秒内自动重新挂载所有探针，无需人工干预。

### 4.4 零事件丢失架构

使用 BPF ring buffer 替代 perf buffer，配合用户态高效轮询，在 48 小时/2000 万事件规模下实现 0 丢失。

### 4.5 21 个 BPF 程序全覆盖

| 类型 | 数量 | 覆盖范围 |
|------|------|----------|
| uprobe/uretprobe | 8 对（16 个） | RocksDB GET/PUT/WRITE/DELETE/ITER\_NEW/ITER\_SEEK/TXN\_BEGIN/TXN\_COMMIT |
| kprobe/kretprobe | 2 对（4 个） | tcp\_sendmsg / tcp\_recvmsg |
| tracepoint | 1 个 | sys\_enter（syscall 分布） |

---

## 5. 项目时间线

| 周次 | 日期 | 工作内容 | 里程碑 |
|------|------|----------|--------|
| Week 1 | 03-23 ~ 03-29 | CKB 架构调研 + Aya 学习 + 开发环境搭建 | |
| Week 2 | 03-30 ~ 04-05 | 符号侦察 → `ckb-probe symbols` | 里程碑 1（部分） |
| Week 3 | 04-06 ~ 04-12 | eBPF 可行性验证 → `ckb-probe check` | 里程碑 1 完成 |
| Week 4 | 04-13 ~ 04-19 | RocksDB 核心探针 + EWMA 异常检测 | 里程碑 2（提前） |
| Week 5 | 04-20 ~ 04-26 | 性能优化 + Docker + S-4 + P-1\~P-4 测试 | |
| Week 6 | 04-27 ~ 05-03 | 48h 稳定性测试 + 案例分析 | |
| Week 7 | 05-04 ~ 05-06 | JSON 优化 + demo walkthrough 文档 | |
| Week 8 | 05-07 | 文档维护 + v0.1.0 发布 + 结项报告 | 项目结束 |

---

## 6. 代码统计

| 模块 | 行数 | 说明 |
|------|------|------|
| ckb-probe（用户态） | 3,115 行 | CLI 主程序、子命令、输出格式化 |
| ckb-probe-common | 567 行 | BPF/用户态共享数据结构 |
| ckb-probe-ebpf | 458 行 | BPF 内核态程序 |
| xtask | 47 行 | 构建辅助 |
| **总计** | **~4,187 行 Rust** | |

---

## 7. 已知限制与未来计划

### 7.1 已知限制

| # | 限制 | 说明 |
|---|------|------|
| L-1 | P2P 网络层子命令缺失 | eBPF 中已实现 kprobe 网络监控，但尚未提供专用 `ckb-probe net` 子命令 |
| L-2 | 系统调用层子命令缺失 | eBPF 中已实现 tracepoint，但尚未提供专用 `ckb-probe syscall` 子命令 |
| L-3 | TUI 仪表盘未实现 | 原计划基于 ratatui，当前使用 CLI 表格输出替代 |
| L-4 | Web5 DID/VC 功能未实现 | 计划作为未来版本的可选功能 |
| L-5 | Prometheus exporter 未实现 | 当前通过 --json 输出可对接外部监控系统 |
| L-6 | F-4 偏差 | 追踪 ITER\_NEW/TXN\_COMMIT 替代 DELETE/ITER\_SEEK。原因：CKB 不使用 rocksdb\_delete；ITER\_NEW 和 TXN\_COMMIT 更能代表 CKB 的实际访问模式 |
| L-7 | 演示视频替代 | 以全面的 demo-walkthrough 文档（EN/ZH）替代演示视频 |
| L-8 | 仅支持 CKB 测试网 | 设计上仅面向测试网 |

### 7.2 未来计划

- **v0.2.0**：`ckb-probe net` 子命令（P2P 连接数、消息大小分布）
- **v0.2.0**：`ckb-probe syscall` 子命令（系统调用热力图）
- **v0.3.0**：TUI 仪表盘（基于 ratatui）
- **v0.3.0**：Prometheus metrics exporter
- **v0.4.0**：Web5 DID/VC 可选功能

---

## 8. 资金使用

| 类别 | 金额 | 说明 |
|------|------|------|
| 云服务器 | $350 | VPS（Linux 5.15+，4 核 8GB），开发 + CKB 测试网节点运行，8 周 |
| 开发者报酬 | $450 | 核心开发，约 20-30 小时/周 x 8 周 |
| 文档与社区 | $200 | 双语文档、架构图、2 次月度分享、结项报告 |
| **总计** | **$1,000** | |

---

## 9. 附录：文档索引

| 文档 | 中文 | 英文 |
|------|------|------|
| 代码架构 | [code-architecture_zh.md](code-architecture_zh.md) | [code-architecture.md](code-architecture.md) |
| 快速开始 | [getting-started_zh.md](getting-started_zh.md) | [getting-started_en.md](getting-started_en.md) |
| Docker 快速开始 | [docker-quickstart_zh.md](docker-quickstart_zh.md) | [docker-quickstart.md](docker-quickstart.md) |
| 技术深入 | [technical-deep-dive_zh.md](technical-deep-dive_zh.md) | [technical-deep-dive_en.md](technical-deep-dive_en.md) |
| 测试基础设施 | [test-infrastructure_zh.md](test-infrastructure_zh.md) | [test-infrastructure_en.md](test-infrastructure_en.md) |
| 演示 Walkthrough | [demo-walkthrough_zh.md](demo-walkthrough_zh.md) | [demo-walkthrough_en.md](demo-walkthrough_en.md) |
| 稳定性报告 | [STABILITY-REPORT_zh.md](STABILITY-REPORT_zh.md) | [STABILITY-REPORT.md](STABILITY-REPORT.md) |
| 案例分析 | [CASE-STUDY-REPORT_zh.md](CASE-STUDY-REPORT_zh.md) | [CASE_STUDY_BUNDLE.md](CASE_STUDY_BUNDLE.md) |
| 中期报告 | [midterm-report_zh.md](midterm-report_zh.md) | [midterm-report.md](midterm-report.md) |
| 结项报告 | [final-report_zh.md](final-report_zh.md) | [final-report_en.md](final-report_en.md) |

---

*ckb-probe v0.1.0 -- 基于 eBPF 的 CKB 测试网全节点深度可观测性工具*
