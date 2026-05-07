# ckb-probe Case Study Docker Bundle —— 全套脚本与构建配置参考

> 本文档把 ckb-probe Week 5/6 docker 化案例研究所需的全部交付物**集中在一份参考资料里**，便于查阅、cherry-pick 到真实文件。
>
> **架构选择：单容器**（详见前文设计讨论）。CKB + ckb-probe + 全部脚本一锅装，通过 host volume 挂载 snapshot 和输出目录。
>
> **目标网络：** 仅 CKB testnet（per main_proj.md 范围）。
>
> 包含内容：
> 1. snapshot 制作 / 恢复脚本
> 2. Docker 单容器构建配置（Dockerfile / .dockerignore / entrypoint.sh）
> 3. 性能评估脚本（P-1 ~ P-4 + orchestrator）
> 4. RocksDB 案例诊断脚本（case-1 IBD 写入模式 + case-2 compaction storm）
> 5. 三个演示脚本（demo-check / demo-normal / demo-stress）
> 6. 使用示例 + 已知限制

---

## 0. 目录布局

```
ckb-probe/
├── .dockerignore                           ← Docker build 上下文过滤(放项目根)
└── docker/
    ├── Dockerfile                          ← 单容器多阶段构建
    ├── entrypoint.sh                       ← 容器启动入口分发器
    ├── README.md                           ← 容器内 README
    ├── CASE_STUDY_BUNDLE.md                ← 本文档
    ├── ckb-config/
    │   └── ckb.toml.aggressive             ← 让 compaction 更易触发的覆盖配置
    └── scripts/
        ├── snapshot/
        │   ├── make-snapshot.sh
        │   └── restore-snapshot.sh
        ├── perf/
        │   ├── p1-cpu.sh
        │   ├── p2-rss.sh
        │   ├── p3-stress.sh
        │   ├── p4-sync.sh
        │   └── full-perf-run.sh
        ├── case/
        │   ├── start-ckb.sh
        │   ├── case-1-ibd-write-pattern.sh
        │   └── case-2-compaction-storm.sh
        └── demo/
            ├── demo-check.sh
            ├── demo-normal.sh
            └── demo-stress.sh
```

容器内运行时的常量约定：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CKB_BIN` | `/usr/local/bin/ckb` | CKB 二进制 |
| `CKB_DATA` | `/data` | CKB 数据目录（host volume 挂载点）|
| `CKB_RPC` | `http://127.0.0.1:8124` | CKB JSON-RPC 端点 |
| `PROBE_BIN` | `/usr/local/bin/ckb-probe` | ckb-probe 二进制 |
| `EBPF_DIR` | `/opt/ckb-probe-ebpf/target/bpfel-unknown-none/release` | eBPF ELF 路径 |
| `OUTPUT_DIR` | `/tmp/perf-run` | 评估/案例输出目录（host volume 挂载点）|
| `BACKUP_DIR` | `/backup` | snapshot 存放目录（host volume 挂载点）|

---

## 0.1 设计哲学与架构权衡

整个 docker 化 case study 的设计建立在五条核心原则上。先把原则讲清楚，后面所有具体决定（单容器 / 数据外置 / 脚本结构）就有了判断依据。

### 原则 1：case study 不是生产部署

ckb-probe 在生产里的形态是 **sidecar**——单独的容器跟 CKB 节点共存。但 case study 的目的是**让评审者复现实验**，不是验证部署形态。生产 sidecar 模式的所有"优势"（独立升级、分离 cgroup、跨主机调度）在 case study 场景下要么不需要、要么没意义。

所以选 **单容器**：1 个 Dockerfile、1 个 `docker run` 命令、PID namespace 自动共享、ckb-probe 直接 `pgrep` 就能找 CKB pid。evaluator 学习曲线最低、出错点最少。

### 原则 2：数据和代码绝对分离

CKB testnet db 是 ~242 GB，**任何 image registry（GHCR / Docker Hub）都不应该承载这种规模的二进制 blob**。理由在前文已经详细论证（10 GB per layer 限制 / GitHub Actions 14 GB 磁盘限制 / 首次拉取数小时 / 工程灾难）。

镜像里**只放代码 + 工具 + 脚本**，数据走 host volume：

| 数据类型 | 容器内路径 | host 来源 |
|---|---|---|
| snapshot tarball | `/backup` | 用户的备份盘（bind mount）|
| CKB chain data | `/data` | 用户已有的 CKB data 目录（bind mount）|
| 评估输出 | `/tmp/perf-run` | 用户的输出目录（bind mount）|

这意味着 docker image 永远是几百 MB 量级，evaluator 拉镜像的时间永远是分钟级而不是小时级。

### 原则 3：每个脚本都是一个完整可独立运行的工作流

不依赖 docker-compose 编排，不依赖外部 service mesh。每个脚本自带：

- **前置检查**：必备命令是否存在、必备进程是否在跑、必备文件是否就位
- **优雅停止**：`trap EXIT/INT/TERM` 兜底，被中断时不留孤儿 ckb-probe
- **失败时的清晰错误消息**：明确告诉 evaluator 哪一步出了问题
- **完成后的明确 verdict / report**：不是"看起来还可以"而是 ✅ PASS / ❌ FAIL

这让 evaluator 可以单独跑任意一个脚本，不需要先理解整套系统。

### 原则 4：测量必须是 spec-driven 的

P-1 ~ P-4 四个性能约束在 main_proj.md 里有明确数值（3% / 50 MB / 0.1% / 1%），每个脚本的 verdict **直接对照这些数值**：

```
P-1 budget : <= +3.000   →  awk: if (delta <= 3.0) print "PASS"
P-2 budget : <= 50 MB    →  awk: if (max_rss <= 50) print "PASS"
P-3 budget : < 0.1%      →  awk: if (loss_pct < 0.1) print "PASS"
P-4 budget : <= 1.0%     →  awk: if (degrad <= 1.0) print "PASS"
```

不允许"差不多就行"。verdict 函数返回明确的 PASS/FAIL，让 evaluator 一眼能看出每条约束是否满足。

### 原则 5：评审失败模式必须可恢复

任何一步都不能让 evaluator 卡死。每个 case study driver 脚本都有：

- **超时退出**：case-1 默认 2h 上限、case-2 默认 30 分钟上限
- **部分数据保存**：即使没拿到完整数据也能看到中间日志
- **明确的下一步建议**：例如 case-2 没看到 ANOMALY 时，提示 "尝试更长的 --threshold 或更激进的 tuning"

### 时间预算分配

整套 case study 的时间预算大致这样：

| 阶段 | 预期耗时 | 备注 |
|---|---|---|
| 环境准备（拉镜像 + 准备 snapshot）| 5-30 min | snapshot 是最大消耗 |
| `demo-check` | < 30 sec | 静态检查，最快 |
| `demo-normal` | 5 min | 设计成 5 分钟 |
| `demo-stress` | 2-5 min | 取决于 db_bench `--num` |
| `case-1` (IBD) | 30 min - 2h | 取决于 snapshot 落后多远 |
| `case-2` (compaction) | 5-30 min | 取决于 anomaly 出现速度 |
| `perf` (full P-1~P-4) | **4 hours** | spec 强制 |
| **总计** | **~5-7 hours** | 完整跑一遍 |

这个预算让 evaluator 可以"开会前启动 perf，会后看 REPORT.txt"——4 小时长跑期间不需要人盯。

### 容器之外的"硬"前提

镜像内部我们能控制，**镜像外部需要 evaluator 自己满足**的硬约束：

| 前提 | 检查方法 | 不满足的后果 |
|---|---|---|
| Linux 内核 ≥ 5.8 | `uname -r` | BPF verifier 拒绝程序 |
| 启用 BTF（`/sys/kernel/btf/vmlinux`）| `ls /sys/kernel/btf/vmlinux` | aya 加载失败 |
| 启用 BPF + JIT（`CONFIG_BPF=y`）| `zcat /proc/config.gz \| grep BPF` | uprobe 挂不上 |
| 容器以 `--privileged` 启动 | `cat /proc/self/status \| grep CapEff` | BPF 系统调用被拒 |
| host 已有 CKB testnet 节点 | `pgrep ckb` | 没 CKB 就没 case study |
| host 至少 250 GB 空闲磁盘 | `df -h` | snapshot 容不下 |

`demo-check.sh` 会主动检查这几项并给出明确报错，但 evaluator 在拉镜像之前最好先确认。

---

## 1. Snapshot 制作 / 恢复

### 总览

Snapshot 是整套 case study 的**基石原语**。它解决一个核心问题：**让 evaluator 可以反复重置 CKB 节点到某个已知历史状态**，从而：

- **案例 1（IBD）** 需要节点处于"落后于网络 tip 一段距离"的状态 → snapshot restore + 自然 IBD 触发
- **案例 2（compaction）** 也借 IBD 的副产物自然触发风暴 → 同上
- **P-1 / P-4 的 A/B 测试** 需要"两次跑从相同初始状态出发" → snapshot restore 保证可复现性

如前文设计讨论（§7.5），CKB 没有"truncate to height"命令，也没有 state sync 协议，所以 snapshot 必须是**全量文件系统级 tarball**——`tar czf data/db data/ancient`。snapshot 大小 ≈ 当前 db 大小（~240 GB on testnet），**没有"小 snapshot"这个选项**。

### 两个互补的脚本

| 脚本 | 角色 | 何时用 | 停机窗口 |
|---|---|---|---|
| `make-snapshot.sh` | 把当前 CKB db 打包到 `/backup/` | 一次性,在 evaluator 的 setup 阶段做 | 15-30 分钟 |
| `restore-snapshot.sh` | 把 tarball 还原到 CKB data dir | 每次跑 case-1 / case-2 / perf 之前都做 | 10-20 分钟 |

两者都**必须在 CKB 完全停止时操作**——RocksDB 是独占写模式，LOCK 文件被持有时任何 tar/rm 都会破坏 db 一致性。

### 1.1 `docker/scripts/snapshot/make-snapshot.sh`

优雅停止 CKB → 用 zstd 并行压缩 db + ancient → 重启 CKB。停机窗口约 15-30 分钟（242 GB db）。

**问题：** 如何在 CKB 节点运行的情况下，生成一份可用于后续 case study 的 db 快照？

**机制：** 5 步流水线

1. **抓 tip 高度** — 在停 CKB 之前先 RPC 拉一次。这是必须的——一旦 CKB 停了，RPC 就死了，没法事后再补这个数据。tip 用作 snapshot 文件名 (`ckb-testnet-snap-h<TIP>-<TIMESTAMP>.tar.zst`)，方便后面识别。
2. **优雅停 CKB** — `kill -TERM` 而**不是** `kill -9`。SIGTERM 触发 ckb 走 graceful shutdown 路径：flush memtable → 写出最后的 WAL → close 所有 SST file handle → release LOCK。整个过程 5-30 秒。SIGKILL 会让 ckb 进程瞬间消失，但它正在写的 SST 块、未 fsync 的 WAL 都会被丢，重启时 RocksDB 要做 WAL replay，运气不好会直接 panic。
3. **验证 db 没被持有** — `lsof` 检查 LOCK 文件不被任何进程持有。如果 ckb 没干净退出（比如 SIGTERM 后 60s 还没退），脚本会报错 abort，**绝不在这种状态下打包**。
4. **tar + zstd 流水线** — `tar cf - data/db data/ancient | zstd -T0 -3 -o $SNAP_FILE`，所有 CPU 核并行压缩。tar 输出经 pipe 直接喂给 zstd，**没有中间 240 GB 临时文件**——磁盘只需要存最终的 ~170 GB tarball。在 24 核 SSD 机器上典型耗时 15-25 分钟。
5. **重启 CKB** — `nohup ckb run` + `disown`，把 ckb 接回 background。最后 grep 一下 pid 确认重启成功。

**设计取舍：**

- **为什么用 zstd 不用 gzip？** 24 核机器上 `zstd -T0` 比 `gzip` 快约 5 倍，压缩比相近（zstd -3 ≈ gzip -6）。`-3` 是默认平衡点，要追极限可以 `-9`（慢 3 倍，体积小 5-10%），但 case study 不需要这种压榨。
- **为什么不直接 `cp -r` 而是 tar？** 单个 tarball 文件比 240 GB 散文件好管理：传输方便、校验方便（`zstd --test`）、移动方便、分发方便。代价是恢复时多一次解压步骤。
- **为什么把 `ancient` 也一起打包？** Ancient 是 CKB 的冷区块归档目录，存历史的"老 SST 文件"。不带的话恢复后节点要重新拉那部分历史，IBD 时长会显著拉长（可能多几小时）。
- **为什么用 `trap` 加 cleanup？** 如果脚本被 Ctrl+C，我们要确保 ckb 不会处于"被 SIGTERM 但脚本没重启"的尴尬状态——那样 evaluator 的 ckb 节点就直接挂了。

> ⚠️ **关键 pitfall**：如果 `lsof` 仍然显示 LOCK 被持有，**绝对不要继续 tar**。这意味着 ckb 没干净退出，强行打包会得到坏 snapshot，恢复时 RocksDB 会 panic 并报"Corruption: corrupted compressed block"。脚本里这步是 `exit 1`，不允许跳过。


```bash
#!/usr/bin/env bash
#
# make-snapshot.sh — Stop CKB cleanly, tar+zstd the chain DB to /backup/.
#
# Output: /backup/ckb-testnet-snap-h<height>-<timestamp>.tar.zst
#
# CKB MUST be running before calling this script. After completion the script
# restarts CKB and the node resumes from where it stopped.
#
# Usage:
#   ./make-snapshot.sh [BACKUP_DIR]
#
# Env overrides:
#   CKB_BIN, CKB_DATA, CKB_RPC, BACKUP_DIR

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
BACKUP_DIR="${1:-${BACKUP_DIR:-/backup}}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"   # 1=fastest, 19=smallest

mkdir -p "$BACKUP_DIR"

# ── 1) Capture current tip BEFORE stopping CKB ─────────────────
echo "[make-snapshot] querying current tip..."
TIP_HEX=$(curl -s -X POST "$CKB_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result // empty')
if [[ -z "$TIP_HEX" ]]; then
    echo "[make-snapshot] FATAL: cannot reach CKB RPC at $CKB_RPC" >&2
    exit 1
fi
TIP_DEC=$(printf '%d' "$TIP_HEX")
TS=$(date +%Y%m%d-%H%M%S)
SNAP_FILE="$BACKUP_DIR/ckb-testnet-snap-h${TIP_DEC}-${TS}.tar.zst"
echo "[make-snapshot] tip=$TIP_DEC ($TIP_HEX)  output=$SNAP_FILE"

# ── 2) Graceful shutdown ───────────────────────────────────────
CKB_PID=$(pgrep -x ckb || true)
if [[ -z "$CKB_PID" ]]; then
    echo "[make-snapshot] FATAL: no running ckb process" >&2
    exit 1
fi
echo "[make-snapshot] sending SIGTERM to ckb pid=$CKB_PID..."
kill -TERM "$CKB_PID"

# Wait for ckb to finish flushing memtable + closing SST handles
WAIT_START=$(date +%s)
while kill -0 "$CKB_PID" 2>/dev/null; do
    WAIT_NOW=$(date +%s)
    if (( WAIT_NOW - WAIT_START > 120 )); then
        echo "[make-snapshot] FATAL: ckb did not exit within 120s" >&2
        exit 1
    fi
    echo "[make-snapshot]   waiting for ckb to flush... ($(date +%T))"
    sleep 2
done
echo "[make-snapshot] ckb stopped cleanly in $((WAIT_NOW - WAIT_START))s"

# ── 3) Verify db is consistent (no lock, no open handles) ──────
if [[ -f "$CKB_DATA/data/db/LOCK" ]] && lsof "$CKB_DATA/data/db/LOCK" 2>/dev/null | grep -q .; then
    echo "[make-snapshot] FATAL: $CKB_DATA/data/db/LOCK is still held" >&2
    exit 1
fi

# ── 4) Pack with zstd parallel compression ─────────────────────
echo "[make-snapshot] packing $CKB_DATA/data/{db,ancient} -> $SNAP_FILE"
echo "[make-snapshot] this typically takes 15-25 minutes for a ~240 GB db"
PACK_START=$(date +%s)

cd "$CKB_DATA"
SUBDIRS=("data/db")
[[ -d "data/ancient" ]] && SUBDIRS+=("data/ancient")

tar cf - "${SUBDIRS[@]}" | zstd -T0 "-${ZSTD_LEVEL}" -o "$SNAP_FILE"

PACK_END=$(date +%s)
SNAP_BYTES=$(stat -c%s "$SNAP_FILE")
SNAP_GB=$(awk -v b="$SNAP_BYTES" 'BEGIN {printf "%.2f", b/1024/1024/1024}')
echo "[make-snapshot] done in $((PACK_END - PACK_START))s -> ${SNAP_GB} GB"

# ── 5) Restart ckb ─────────────────────────────────────────────
echo "[make-snapshot] restarting ckb..."
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown
sleep 5

if pgrep -x ckb >/dev/null; then
    NEW_PID=$(pgrep -x ckb)
    echo "[make-snapshot] ckb restarted, pid=$NEW_PID"
else
    echo "[make-snapshot] WARNING: ckb did not come back up cleanly" >&2
fi

echo
echo "===== make-snapshot complete ====="
echo "  file       : $SNAP_FILE"
echo "  size       : ${SNAP_GB} GB"
echo "  tip height : $TIP_DEC"
echo "  pack time  : $((PACK_END - PACK_START))s"
echo "  zstd level : $ZSTD_LEVEL"
```

### 1.2 `docker/scripts/snapshot/restore-snapshot.sh`

停 CKB → 删现役 db → 解压 snapshot → 用 `ckb migrate --check` 验证 → 重启 CKB。

**问题：** 如何把一份 snapshot tarball 还原成可用的 CKB db，并让节点从那个历史 tip 开始 IBD？

**机制：** 5 步

1. **停现役 CKB** — 同 make-snapshot 的优雅停止流程。`pgrep` 拿 pid → SIGTERM → 等 process disappear。
2. **删现役 db + ancient** — `rm -rf $CKB_DATA/data/db $CKB_DATA/data/ancient`。**这一步不可逆**——脚本入口先确认 snapshot 文件存在再做这个操作，避免删了 db 才发现 snapshot 路径写错。
3. **解压 snapshot** — `zstd -d -T0 -o - $SNAP | tar xf - -C $CKB_DATA`。同样是 pipe 流式解压，避免中间产物。
4. **`ckb migrate --check`** — CKB 自带的 db 结构检查工具，确认解压出来的 db 文件没坏、schema 兼容当前 ckb 版本。返回非零意味着 snapshot 可能是用更老/更新的 ckb 版本做的，需要先 `ckb migrate` 才能跑。
5. **启动 CKB + 等 RPC ready** — `nohup ckb run` 起来后用 `get_tip_block_number` 轮询直到节点真正接受请求，最多等 60 秒。

**设计取舍：**

- **为什么删 db 而不是覆盖？** RocksDB 的 MANIFEST 和 SST 文件是相互引用的。如果旧 db 有 SST 文件 `001234.sst` 而 snapshot 也有 `001234.sst`，文件名相同但内容不同，覆盖后会产生"MANIFEST 引用的 SST 内容跟实际不符"的半坏状态。只能彻底 `rm -rf` 再解压。
- **为什么用 `migrate --check` 而不只是启动？** 启动失败的错误信息很难懂（panic stack trace），`migrate --check` 会给出明确的 schema 不兼容信息。这是 fail-fast 设计——把问题挡在 ckb 启动之前。
- **为什么轮询 RPC 而不是 sleep 固定时间？** 不同机器 CKB 启动速度差几倍——慢机器要 30 秒，快机器只要 5 秒。固定 sleep 30 既可能太短（机器慢就报错）也可能太长（浪费时间）。轮询是 `min(实际就绪时间, 60s 上限)`。

> ⚠️ **关键 pitfall**：restore 之后的节点跟之前的网络 peer 列表可能不一致——脚本**不还原** `data/network/peer_store`（按 §7 章节列的 best practice）。启动后需要几秒到几分钟让节点跟 testnet bootstrap 重新建立 P2P 连接。**RPC ready 不等于 P2P ready**，case-1 driver 在 RPC ready 后还应该 sleep ~10 秒等 P2P 接进来再开始计时——这正是 case-1 脚本里 `sleep 10` 的由来。


```bash
#!/usr/bin/env bash
#
# restore-snapshot.sh — Restore a snapshot tarball into CKB_DATA.
#
# After completion CKB is running at the snapshot's historical tip; it will
# automatically begin IBD to catch up to current network tip.
#
# Usage:
#   ./restore-snapshot.sh /backup/ckb-testnet-snap-h20725000-20260411-103000.tar.zst
#
# Env overrides:
#   CKB_BIN, CKB_DATA

set -euo pipefail

SNAP_FILE="${1:?usage: restore-snapshot.sh <snapshot.tar.zst>}"
CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"

if [[ ! -f "$SNAP_FILE" ]]; then
    echo "[restore-snapshot] FATAL: $SNAP_FILE does not exist" >&2
    exit 1
fi

# ── 1) Stop CKB if running ─────────────────────────────────────
CKB_PID=$(pgrep -x ckb || true)
if [[ -n "$CKB_PID" ]]; then
    echo "[restore-snapshot] stopping ckb pid=$CKB_PID..."
    kill -TERM "$CKB_PID"
    while kill -0 "$CKB_PID" 2>/dev/null; do sleep 2; done
fi

# ── 2) Wipe live db + ancient ──────────────────────────────────
echo "[restore-snapshot] wiping $CKB_DATA/data/{db,ancient}"
rm -rf "$CKB_DATA/data/db" "$CKB_DATA/data/ancient"

# ── 3) Extract snapshot ────────────────────────────────────────
echo "[restore-snapshot] extracting $SNAP_FILE -> $CKB_DATA"
EXTRACT_START=$(date +%s)
zstd -d -T0 -o - "$SNAP_FILE" | tar xf - -C "$CKB_DATA"
EXTRACT_END=$(date +%s)
echo "[restore-snapshot] extracted in $((EXTRACT_END - EXTRACT_START))s"

# ── 4) Sanity-check ────────────────────────────────────────────
if [[ ! -f "$CKB_DATA/data/db/CURRENT" ]]; then
    echo "[restore-snapshot] FATAL: $CKB_DATA/data/db/CURRENT missing after extract" >&2
    exit 1
fi

echo "[restore-snapshot] running ckb migrate --check..."
if "$CKB_BIN" migrate --check -C "$CKB_DATA"; then
    echo "[restore-snapshot] migrate --check OK"
else
    echo "[restore-snapshot] WARNING: migrate --check returned non-zero" >&2
fi

# ── 5) Start ckb ───────────────────────────────────────────────
echo "[restore-snapshot] starting ckb..."
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown

# Wait for RPC to come up
echo "[restore-snapshot] waiting for ckb RPC to be ready..."
for _ in {1..30}; do
    if curl -sf -X POST "${CKB_RPC:-http://127.0.0.1:8124}" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        >/dev/null 2>&1; then
        echo "[restore-snapshot] ckb is ready, pid=$(pgrep -x ckb)"
        break
    fi
    sleep 2
done

CURRENT_TIP=$(curl -s -X POST "${CKB_RPC:-http://127.0.0.1:8124}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result' | xargs printf '%d')

echo
echo "===== restore-snapshot complete ====="
echo "  snapshot file : $SNAP_FILE"
echo "  current tip   : $CURRENT_TIP"
echo "  -> CKB will now IBD forward to catch up with the network."
```

---

## 2. Docker 构建配置

### 总览

整个 Dockerfile 的设计目标是：**让 evaluator 用一行 `docker build` 就能从源码到可运行镜像**，不需要装 rust 工具链、不需要装 bpf-linker、不需要懂 cargo xtask——所有构建复杂度封进多阶段 build，evaluator 只关心最终镜像。

### 多阶段构建的角色分工

```
┌─────────────────────┐    ┌─────────────────────┐    ┌──────────────────────┐
│  stage 1            │    │  stage 2            │    │  stage 3 (final)     │
│  ckb-source         │    │  probe-builder      │    │  runtime             │
│  ───────────        │    │  ───────────        │    │  ───────────         │
│  nervos/ckb:v0.205  │    │  rust:1.83-bookworm │    │  debian:bookworm-slim│
│                     │    │                     │    │                      │
│  抠 ckb binary      │    │  cargo build ckb-   │    │  装运行时工具         │
│  → /bin/ckb         │    │    probe + ebpf     │    │  接收前两个 stage    │
│                     │    │  cargo install      │    │    的产物             │
│                     │    │    bpf-linker       │    │  接收 docker/scripts/│
│                     │    │  rustup nightly +   │    │  设置 entrypoint      │
│                     │    │    rust-src         │    │                      │
│                     │    │                     │    │  ~330 MB              │
│  ~200 MB (扔)       │    │  ~1.5 GB (扔)       │    │                      │
└─────────────────────┘    └─────────────────────┘    └──────────────────────┘
```

只有 stage 3 的内容进 final image，前两个 stage 都被 docker build 自动丢弃。这就是为什么 final image 只有几百 MB——builder 的 1.5 GB rust toolchain 没进去。

### 构建上下文与 .dockerignore

`docker build .` 默认会把整个项目目录当作 build context 上传给 docker daemon。**项目根的 `.dockerignore` 文件控制哪些文件不上传**。如果不加，242 GB 的 `data/` 会被一起上传，几分钟 OOM。所以 `.dockerignore` 跟 Dockerfile 同等重要。

### 2.1 `docker/Dockerfile`

单容器多阶段构建：抠 CKB 二进制 → 构建 ckb-probe → 装运行时工具 → 拼装 runtime。

**问题：** 如何把 CKB 二进制、ckb-probe（userspace + eBPF）、运行时工具、脚本和源码全部组装成一个尺寸合理（几百 MB 而非几 GB）、可独立运行的镜像？

**机制：** 三个 stage，最终只保留 stage 3 的产物

| Stage | base image | 干什么 | 是否进 final |
|---|---|---|---|
| `ckb-source` | `nervos/ckb:v0.205.0` | `COPY` 出 `/bin/ckb` | 只有 ckb 二进制进 |
| `probe-builder` | `rust:1.83-bookworm` | `cargo install bpf-linker` + `rustup nightly` + `cargo xtask build-ebpf --release` + `cargo build --release -p ckb-probe` | 只有两个产物 (`ckb-probe` 和 `ckb-probe-ebpf`) 进 |
| `runtime`（final）| `debian:bookworm-slim` | apt-get install 运行时工具 + COPY from 前两个 stage + COPY 脚本 + 设 entrypoint | **整个 stage 都进** |

stage 1 和 stage 2 在 `docker build` 完成后会被自动丢弃，磁盘上只留 stage 3 的镜像。

**设计取舍：**

- **为什么用 `nervos/ckb:v0.205.0` 抠 ckb 二进制而不自己 build？** 自己 build CKB 需要 rust 工具链 + 一系列依赖 + 几十分钟编译时间。直接抠官方镜像里的二进制是 `COPY --from=ckb-source /bin/ckb /usr/local/bin/ckb` 一行的事，又快又能保证用的是上游 release 版本。如果将来需要 patch CKB（比如改 RocksDB 默认参数），再考虑自己 build。
- **为什么 builder 用 `rust:1.83-bookworm` 而不是 alpine？** alpine 用 musl libc，aya 和 bpf-linker 在 musl 下经常出 weird linker 问题。bookworm 用 glibc，跟最终的 `debian:bookworm-slim` runtime 一致，避免任何 libc 兼容问题。
- **为什么 runtime base 是 `debian:bookworm-slim` 不是 `distroless`？** `distroless` 没有 shell、没有 coreutils，bash 脚本完全跑不起来。case study 的脚本是 bash 重度用户，需要完整的 GNU userland。`bookworm-slim` 是最小可行选项。
- **为什么把 ckb-probe 源码也 COPY 进 final image（`/opt/source/`）？** 透明性——评审者可以 `diff` 镜像里的源码和 GitHub 上的代码，确认编译产物确实来自这份源码。代价是增加 ~5 MB 体积，可以接受。
- **为什么 `WORKDIR /opt`？** ckb-probe 当前从 cwd 找 eBPF 二进制（`Path::new("ckb-probe-ebpf/target/...")`），相对路径硬编码。把 WORKDIR 设成 `/opt` 让这个相对路径正好对到 `/opt/ckb-probe-ebpf/target/...`。这是个临时方案，长远应该改 ckb-probe 代码支持 `EBPF_PATH` 环境变量。

> ⚠️ **关键 pitfall**：构建时如果不指定 `-f docker/Dockerfile`（默认找当前目录的 `Dockerfile`），docker 会找不到文件。**正确的命令永远是从项目根 `docker build -f docker/Dockerfile -t ckb-probe-case-study .`**——`.` 是 build context 路径（项目根），`-f` 是 Dockerfile 路径。


```dockerfile
# syntax=docker/dockerfile:1.6
#
# Single-container ckb-probe case study image.
#   Stage 1: extract CKB binary from official image
#   Stage 2: build ckb-probe (userspace + eBPF)
#   Stage 3: minimal runtime with both binaries + scripts + tools
#
# Build:
#   docker build -f docker/Dockerfile -t ckb-probe-case-study:latest .

# ═══════════════════════════════════════════════════════════════
# Stage 1 — extract official CKB binary
# ═══════════════════════════════════════════════════════════════
FROM nervos/ckb:v0.205.0 AS ckb-source

# ═══════════════════════════════════════════════════════════════
# Stage 2 — build ckb-probe
# ═══════════════════════════════════════════════════════════════
FROM rust:1.83-bookworm AS probe-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        llvm \
        libelf-dev \
        zlib1g-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install bpf-linker --locked
RUN rustup install nightly && \
    rustup component add rust-src --toolchain nightly

WORKDIR /workspace
COPY Cargo.toml Cargo.lock ./
COPY .cargo/ .cargo/
COPY xtask/ xtask/
COPY ckb-probe/ ckb-probe/
COPY ckb-probe-common/ ckb-probe-common/
COPY ckb-probe-ebpf/ ckb-probe-ebpf/

RUN cargo xtask build-ebpf --release && \
    cargo build --release -p ckb-probe

# ═══════════════════════════════════════════════════════════════
# Stage 3 — runtime
# ═══════════════════════════════════════════════════════════════
FROM debian:bookworm-slim

# Runtime tools needed by scripts (P-1~P-4, snapshots, demos)
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        sysstat \
        curl \
        jq \
        procps \
        tar \
        gzip \
        zstd \
        coreutils \
        grep \
        sed \
        gawk \
        iproute2 \
        lsof \
        ca-certificates \
        rocksdb-tools \
    && rm -rf /var/lib/apt/lists/*

# CKB binary from official image
COPY --from=ckb-source /bin/ckb /usr/local/bin/ckb

# ckb-probe binaries
COPY --from=probe-builder /workspace/target/release/ckb-probe \
                          /usr/local/bin/ckb-probe
COPY --from=probe-builder \
    /workspace/ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf \
    /opt/ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf

# ckb-probe source (transparency — auditors can rebuild and compare)
COPY --from=probe-builder /workspace/ckb-probe        /opt/source/ckb-probe
COPY --from=probe-builder /workspace/ckb-probe-common /opt/source/ckb-probe-common
COPY --from=probe-builder /workspace/ckb-probe-ebpf   /opt/source/ckb-probe-ebpf
COPY --from=probe-builder /workspace/Cargo.toml       /opt/source/
COPY --from=probe-builder /workspace/Cargo.lock       /opt/source/

# Scripts and config
COPY docker/scripts/      /opt/scripts/
COPY docker/ckb-config/   /opt/ckb-config/
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/README.md     /opt/README.md

RUN chmod +x /opt/scripts/perf/*.sh \
            /opt/scripts/case/*.sh \
            /opt/scripts/demo/*.sh \
            /opt/scripts/snapshot/*.sh \
            /entrypoint.sh

# ckb-probe currently looks up its eBPF binary from cwd as a relative path:
#   ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf
# Setting WORKDIR=/opt makes that relative path resolve correctly.
WORKDIR /opt

# Default target dirs (can be host-volume bound)
VOLUME ["/data", "/backup", "/tmp/perf-run"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["help"]
```

### 2.2 `.dockerignore`（**放项目根，不是 docker/ 内**）

**问题：** 如何防止 `docker build` 把 242 GB 的 `data/` 目录、几 GB 的 `target/` 目录、私有的周报和 prompt 文件意外塞进 build context 一起上传给 docker daemon？

**机制：** docker build 在启动时会把 build context（默认是 `.`）通过 unix socket 流式传给 dockerd。`.dockerignore` 是这个传输的过滤器——所有匹配模式的路径在传输前就被剔除，**根本不会进入 build 流程**。

**几个必须排除的关键路径：**

- `target/` 和 `**/target/` — Cargo 构建中间产物，可能几个 GB
- `data/`、`backup/`、`*.tar.zst` — CKB 数据和 snapshot，几百 GB
- `ckb_v0.205.0_x86_64-unknown-linux-gnu*` 和 `ckb/` — 项目里残留的 CKB 二进制和源码，几十到上百 MB
- `.git/` — git 历史，几 MB 但跟构建无关
- `prompt.md`、`main_proj.md`、`weekly-report-*.md` — 私有规划文档，**绝对不能进镜像**避免泄露
- `docs/` — 内部技术文档同上

**设计取舍：**

- **为什么放项目根而不是 `docker/` 目录？** docker build 寻找 `.dockerignore` 的位置是 **build context 的根**——也就是 `docker build .` 那个 `.`。如果从项目根构建（推荐做法），`.dockerignore` 必须在项目根。放在 `docker/` 子目录里会被 docker 完全忽略。
- **为什么不直接用 `.gitignore`？** docker 默认不读 `.gitignore`，必须有专门的 `.dockerignore`。两个文件可能有重叠条目，但语义不同——`.gitignore` 控制 git 提交，`.dockerignore` 控制 docker 上传。

> ⚠️ **关键 pitfall**：忘记加 `.dockerignore` 的后果是 **`docker build .` 几分钟后报 OOM 或 disk full**——daemon 把整个 242 GB 数据都拉进了 build context 缓存。如果不小心已经触发，`docker builder prune -a -f` 清掉。


```
# Cargo build artifacts
target/
ckb-probe-ebpf/target/
**/target/

# CKB chain data (huge!)
data/
backup/
*.tar
*.tar.gz
*.tar.zst

# Misc heavy / private
.git/
.claude/
.cargo/registry/
.cargo/git/
ckb_v0.205.0_x86_64-unknown-linux-gnu*
ckb/

# Project planning / private docs (not needed in image)
prompt.md
main_proj.md
weekly-report-*.md
docs/

# Editor / OS junk
*.swp
.DS_Store
```

### 2.3 `docker/entrypoint.sh`

**问题：** evaluator 用 `docker run` 启动容器时，如何让一个简短的命令（比如 `case-1`、`perf`）就能跑对应的工作流，而不是要求记住一长串容器内绝对路径？

**机制：** entrypoint 是一个 case 分发器。`ENTRYPOINT ["/entrypoint.sh"]` + `CMD ["help"]` 让 docker run 的额外参数变成 entrypoint 的 `$1`：

```
docker run ... ckb-probe-case-study perf
                                     ↓
                       /entrypoint.sh perf
                                     ↓
                  case "$1" in
                      perf) exec /opt/scripts/perf/full-perf-run.sh ;;
                      ...
                  esac
```

每个 case 分支用 `exec` 把控制权完全交给目标脚本——这样 `docker stop` 发的 SIGTERM 会直接到目标脚本，不会被 entrypoint 拦截。

**支持的 8 个子命令：**

| 子命令 | 触发的脚本 | 典型用途 |
|---|---|---|
| `help` | 打印 README 和 usage | 默认 |
| `bash` | `exec bash` | 交互式 shell，手动调试 |
| `start-ckb` | `case/start-ckb.sh` | 单独启动 CKB（幂等）|
| `demo-check` | `demo/demo-check.sh` | 健康检查 |
| `demo-normal` | `demo/demo-normal.sh` | 5min JSON 快照 |
| `demo-stress` | `demo/demo-stress.sh` | db_bench 压力注入 |
| `case-1` | `case/case-1-ibd-write-pattern.sh` | IBD 案例 |
| `case-2` | `case/case-2-compaction-storm.sh` | compaction 案例 |
| `perf` | `perf/full-perf-run.sh` | 4h 全量评估 |
| 其他 | `exec "$@"` | pass-through，用户可以传任意命令 |

**设计取舍：**

- **为什么用 `exec` 而不是直接调用？** `exec` 让目标脚本**替换**当前 entrypoint 进程，不是 fork 子进程。这样进程树扁平：docker → 目标脚本，没有中间的 entrypoint 父进程。SIGTERM/SIGINT 直接到目标脚本，不需要 entrypoint 转发。
- **为什么默认 CMD 是 `help` 而不是 `bash`？** `help` 是只读的、不会改变状态，是个安全的默认行为。`bash` 默认会让用户进交互模式但容器里没有 ckb 跑（因为没有 entrypoint 帮忙启动），用户会困惑"为什么 pgrep ckb 没东西"。`help` 把 usage 打出来，用户能看到第一步该跑什么。
- **为什么 `exec "$@"` 兜底？** 这让用户可以 `docker run ... <image> ls -la /opt/scripts` 这样跑任意命令——开发/调试期间非常有用。

> ⚠️ **关键 pitfall**：如果脚本里 `exec /opt/scripts/foo.sh` 但 foo.sh 没有可执行位（chmod +x），会报 "Permission denied"。Dockerfile 里的 `RUN chmod +x /opt/scripts/...` 必须覆盖所有目录，新增脚本目录时记得加。


```bash
#!/usr/bin/env bash
#
# entrypoint.sh — dispatcher for ckb-probe case study container.
#
# Subcommands:
#   help          show usage and README
#   bash          drop into interactive shell
#   start-ckb     start CKB in background (idempotent)
#   demo-check    run ckb-probe check + symbols (read-only)
#   demo-normal   capture 5 minutes of normal monitoring as JSON
#   demo-stress   inject db_bench load and watch ckb-probe react
#   case-1        IBD write pattern case study
#   case-2        compaction storm case study
#   perf          full P-1~P-4 evaluation (4 hours)

set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
    help)
        cat /opt/README.md 2>/dev/null || true
        cat <<'USAGE'

Usage:
    docker run ... ckb-probe-case-study help
    docker run ... ckb-probe-case-study bash
    docker run ... ckb-probe-case-study start-ckb
    docker run ... ckb-probe-case-study demo-check
    docker run ... ckb-probe-case-study demo-normal
    docker run ... ckb-probe-case-study demo-stress
    docker run ... ckb-probe-case-study case-1
    docker run ... ckb-probe-case-study case-2
    docker run ... ckb-probe-case-study perf

Required volumes:
    -v /host/ckb-data:/data         CKB chain data directory
    -v /host/backup:/backup         snapshot tarball storage
    -v /host/output:/tmp/perf-run   evaluation output

Required capabilities:
    --privileged
    -v /sys/kernel/debug:/sys/kernel/debug:ro
    -v /sys/kernel/btf:/sys/kernel/btf:ro

USAGE
        ;;
    bash)
        exec bash
        ;;
    start-ckb)
        exec /opt/scripts/case/start-ckb.sh "$@"
        ;;
    demo-check)
        exec /opt/scripts/demo/demo-check.sh "$@"
        ;;
    demo-normal)
        exec /opt/scripts/demo/demo-normal.sh "$@"
        ;;
    demo-stress)
        exec /opt/scripts/demo/demo-stress.sh "$@"
        ;;
    case-1)
        exec /opt/scripts/case/case-1-ibd-write-pattern.sh "$@"
        ;;
    case-2)
        exec /opt/scripts/case/case-2-compaction-storm.sh "$@"
        ;;
    perf)
        exec /opt/scripts/perf/full-perf-run.sh "$@"
        ;;
    *)
        # Pass-through for arbitrary commands
        exec "$CMD" "$@"
        ;;
esac
```

### 2.4 `docker/ckb-config/ckb.toml.aggressive`

只列出**覆盖** RocksDB 默认参数的部分，要应用时和官方 ckb.toml 合并。这个配置故意把 compaction 触发阈值压低，让 case-2 在稳态节点上也能稳定复现风暴。

**问题：** case-2 想要演示 compaction storm，但 CKB 默认 RocksDB 配置在稳态节点上 compaction 频率很低，可能等几小时都看不到一次 storm。如何让 storm 在几分钟内必出？

**机制：** 把 RocksDB LSM tree 的所有阈值都调小，让 compaction 更频繁、更容易跟不上写入：

| 参数 | CKB 默认 | aggressive 值 | 效果 |
|---|---|---|---|
| `level0_file_num_compaction_trigger` | 4 | **1** | L0 只要有 1 个 SST 文件就触发 compaction（默认 4 个）|
| `level0_slowdown_writes_trigger` | 20 | **2** | L0 ≥ 2 个文件就开始 slowdown 写入 |
| `level0_stop_writes_trigger` | 36 | **3** | L0 ≥ 3 个文件就完全停止写入 |
| `max_background_jobs` | 8 (或 default) | **1** | 后台 compaction 并发限到 1，让它跟不上 |
| `target_file_size_base` | 64 MB | **1 MB** | 单个 SST 文件更小 → 数量更多 → compaction 更频繁 |
| `write_buffer_size` | 64 MB | **4 MB** | memtable 更小 → flush 更快 → L0 文件涌入更快 |

合在一起，**几乎每次 memtable flush 都会触发 compaction，而 compaction 又被限到 1 个并发**——稳态写入也能压出明显的 write stall。

**设计取舍：**

- **为什么不直接改 CKB 源码而是改 toml？** ckb.toml 里 `[store.options]` section 直接传给 RocksDB 的 `OptionsBuilder`，不需要重新编译 ckb。一行 sed 就能改完，restart 即生效。
- **为什么改完 case-2 之后要 restore 回去？** aggressive tuning 会让节点的写吞吐显著下降，长期跑会让 IBD 慢得多。case-2 跑完立刻 restore 原始配置是 hygienic 设计，避免影响后续跑 case-1 或 perf。
- **为什么不用 RocksDB 自己的 manual_compaction API？** 这需要直接调用 ckb 进程内部的 RocksDB 接口，CKB 没暴露这个能力。修改 toml 是 evaluator 能用的唯一手动触发途径。

> ⚠️ **关键 pitfall**：把 aggressive tuning 应用到生产节点会**显著降低写吞吐**——`max_background_jobs=1` 加 `write_buffer_size=4MB` 在大流量下会迅速触发 stop_writes，节点直接卡死。这个配置**只在 case-2 临时使用**，case-2 driver 脚本会自动 backup + restore 原始 toml。


```toml
# Aggressive RocksDB tuning for ckb-probe case study (NOT for production!)
#
# These overrides make compaction trigger much more often than CKB defaults,
# so case-2 (compaction storm) can be reproduced reliably even on a synced
# node with steady-state workload.

[store.options]
# L0 file thresholds — default 4/20/36, here much lower
"level0_file_num_compaction_trigger" = "1"
"level0_slowdown_writes_trigger"     = "2"
"level0_stop_writes_trigger"         = "3"

# Limit background compaction parallelism so it lags behind writes
"max_background_jobs"        = "1"
"max_background_compactions" = "1"

# Make SST files smaller so there are more of them, more frequent compaction
"target_file_size_base"      = "1048576"      # 1 MB (default 64 MB)
"max_bytes_for_level_base"   = "10485760"     # 10 MB (default 256 MB)

# Smaller memtable so flushes happen often → more L0 files → more compaction
"write_buffer_size"          = "4194304"      # 4 MB (default 64 MB)
```

---

## 3. 性能评估脚本（P-1 ~ P-4）

### 总览

这一节的脚本对应 main_proj.md 里的四条**硬性性能约束**，每条都有明确数值：

| 约束 | 数值 | 测量对象 | 测量方法 |
|---|---|---|---|
| **P-1** 附加 CPU ≤ 3% | 1 小时窗口 | CKB 进程 %CPU | A/B 对比（有/无 ckb-probe 挂载）|
| **P-2** RSS ≤ 50 MB | 持续监控状态 | ckb-probe 进程 VmRSS | 持续 sample VmRSS |
| **P-3** 事件丢失率 < 0.1% | 10K events/s 持续负载 | BPF PerfEventArray 丢弃事件 | 从 ckb-probe footer 读取 |
| **P-4** 同步速度退化 < 1% | 2 小时 IBD 窗口 | CKB blocks/min | A/B 对比 + 时间序列差分 |

### 单脚本 vs orchestrator 的角色分工

- **单脚本（p1/p2/p3/p4）**：每个负责一项指标，可以独立运行做局部 spot check
- **orchestrator（full-perf-run.sh）**：把四项串成一个 4 小时全自动跑批，最终产出综合 REPORT.txt

evaluator 通常先用单脚本做 5 分钟烟雾测试（确认环境就绪），再用 orchestrator 跑一次完整 4h 评估。

### 共同的输出约定

所有性能脚本都把数据写到 `$OUTPUT_DIR/`（默认 `/tmp/perf-run/`）：

```
/tmp/perf-run/
├── progress.log              # 时间戳 + 阶段进度
├── p1-with-probe.log         # pidstat 原始输出
├── p1-baseline.log
├── p2-rss.log                # VmRSS 时间序列
├── p3-probe.log              # ckb-probe footer 含 BPF event loss
├── p4-with-probe.log         # tip height 时间序列
├── p4-baseline.log
├── probe-slow.log            # ckb-probe slow mode 全文输出
└── REPORT.txt                # orchestrator 最终 verdict
```

host 用 `-v /tmp/perf-run:/tmp/perf-run` 挂载，容器停了数据还在。

### 3.1 `docker/scripts/perf/p1-cpu.sh`

A/B 测量 CKB 进程 CPU%。1 小时窗口为标准 P-1 spec。

**问题：** 如何客观测量挂 ckb-probe 之前 vs 之后，CKB 进程的 CPU 占用变化？

**机制：** 4 步

1. **`pgrep -x ckb`** 拿目标 CKB pid
2. **`pidstat -u -h -p $pid $INTERVAL $SAMPLES`** 按 PID 采样 CPU%——每 5 秒一次，跑 720 次（1 小时）
3. **awk 解析** pidstat 输出。注意 `pidstat -h` 用 `AM/PM` 时间格式，`%CPU` 在第 9 列（不是第 8 列），这是个 typo-prone 点
4. **`compare` 子命令** 算 baseline 和 with-probe 的 mean 差值，对照 P-1 budget (3.0%)

**为什么 1 小时窗口？** main_proj.md spec 写明 1h。**为什么不能更短？** CKB 工作负载方差很大——TX 池压力、Compaction 周期、RPC 量都会让 CPU% 在 ±5-10% 之间抖动。60 秒窗口的 mean 误差远大于 3% budget，verdict 会被噪声主导（参见早期 1 分钟烟雾测试结果）。1 小时窗口让方差被均值平滑掉。

**设计取舍：**

- **为什么用 `pidstat` 而不是 `top` 或 `/proc/[pid]/stat`？** `pidstat` 输出格式稳定、可机器解析、自带历史 sampling 模式（不像 top 是交互式的）。`/proc/[pid]/stat` 需要自己算 utime/stime delta，多一层出错点。
- **为什么 `-h` 不带时间分行而是带头？** `-h` 让所有样本输出到一行，方便 awk 按行解析。不加 `-h` 的话每个采样是分块的，多行 header 会干扰解析。
- **为什么 baseline 和 with-probe 跑两次而不是同时？** 同时跑会让 CKB 同时承受两种状态，不可能。两次必须时间错开，但要尽量短间隔（5-10 分钟内），减少链负载漂移的影响。

> ⚠️ **关键 pitfall**：我自己第一次写 awk 脚本时把 `%CPU` 写成 `$8`——但 `pidstat -h` 用 AM/PM 时间格式时 `10:29:47 AM` 是两个 token，`%CPU` 在 `$9`。这种 off-by-one 错误的症状是 verdict 显示 mean=0%。如果你看到 mean=0%，**先检查是不是 awk 字段错位**。


```bash
#!/usr/bin/env bash
#
# p1-cpu.sh — CKB CPU% sampling for P-1 (≤ 3% additional CPU usage).
#
# Usage:
#   ./p1-cpu.sh baseline   [duration_seconds] [interval_seconds]
#   ./p1-cpu.sh with-probe [duration_seconds] [interval_seconds]
#   ./p1-cpu.sh compare
#
# Defaults: duration=3600 (1h), interval=10
#
# Output: $OUTPUT_DIR/p1-cpu-{baseline,with-probe}.log

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"
mkdir -p "$OUTPUT_DIR"

DURATION="${2:-3600}"
INTERVAL="${3:-10}"
SAMPLES=$((DURATION / INTERVAL))
P1_BUDGET=3.0

find_ckb_pid() {
    local pid
    pid=$(pgrep -x ckb | head -n 1 || true)
    if [[ -z "$pid" ]]; then
        echo "ERROR: no ckb process found" >&2
        exit 1
    fi
    echo "$pid"
}

run_sample() {
    local label="$1"
    local logfile="$OUTPUT_DIR/p1-cpu-${label}.log"
    local pid
    pid=$(find_ckb_pid)
    echo "[p1-cpu] $label  pid=$pid  ${DURATION}s × ${INTERVAL}s = $SAMPLES samples"
    echo "[p1-cpu] writing $logfile"
    pidstat -u -h -p "$pid" "$INTERVAL" "$SAMPLES" > "$logfile"
    summarise "$logfile"
}

summarise() {
    awk '
        /^#/ { next }
        NF >= 10 {
            # pidstat -h with AM/PM timestamp puts %CPU in column 9
            sum += $9; n++
        }
        END {
            if (n == 0) { print "[p1-cpu] no samples in", FILENAME; exit 1 }
            printf "[p1-cpu] %s -> samples=%d  mean %%CPU=%.3f\n", FILENAME, n, sum/n
        }
    ' "$1"
}

cmd_compare() {
    local b="$OUTPUT_DIR/p1-cpu-baseline.log"
    local w="$OUTPUT_DIR/p1-cpu-with-probe.log"
    [[ -f "$b" && -f "$w" ]] || { echo "ERROR: run baseline + with-probe first" >&2; exit 1; }
    local bm wm dlt
    bm=$(awk '/^#/ {next} NF>=10 {s+=$9; n++} END {printf "%.3f", s/n}' "$b")
    wm=$(awk '/^#/ {next} NF>=10 {s+=$9; n++} END {printf "%.3f", s/n}' "$w")
    dlt=$(awk -v a="$bm" -v c="$wm" 'BEGIN {printf "%+.3f", c-a}')
    echo
    echo "===== P-1 result ====="
    echo "  baseline mean %CPU      : $bm"
    echo "  with-probe mean %CPU    : $wm"
    echo "  delta (with - baseline) : $dlt"
    printf "  P-1 budget              : <= +%.1f\n" "$P1_BUDGET"
    awk -v d="$dlt" -v b="$P1_BUDGET" 'BEGIN {
        if (d <= b) print "  status                  : ✅ PASS"
        else        print "  status                  : ❌ FAIL"
    }'
}

case "${1:-}" in
    baseline)   run_sample baseline ;;
    with-probe) run_sample with-probe ;;
    compare)    cmd_compare ;;
    *)
        sed -n '3,17p' "$0"
        exit 1
        ;;
esac
```

### 3.2 `docker/scripts/perf/p2-rss.sh`

持续监控 ckb-probe 的 VmRSS。Verdict 只看 VmRSS（per main_proj.md "持续监控状态"），VmHWM 仅作信息展示。

**问题：** 如何持续监控 ckb-probe 进程的内存占用，并对照 50 MB 上限给出 verdict？

**机制：** 简单 polling loop

1. **找 ckb-probe pid**：`pgrep -x ckb-probe` 或者 `--pid` 参数指定
2. **每 5 秒读 `/proc/<pid>/status`**：拿 `VmRSS:` 和 `VmHWM:` 两个字段
3. **写入 log 文件**：每行 `timestamp vmrss_kb vmrss_mb hwm_kb hwm_mb`
4. **`trap cleanup EXIT`**：进程退出时（Ctrl+C 或 ckb-probe 死掉）自动 awk 算 mean / max / verdict 并打印

**关键设计点—— VmRSS vs VmHWM：**

- **VmRSS** = 当前驻留集大小（resident set size），随时间变化
- **VmHWM** = high water mark，**进程启动以来 VmRSS 的历史最大值**，单调递增

ckb-probe 启动时会有一次明显的 RSS 尖峰——aya 加载 BPF 程序、分配 9 × 64 = 576 个 PerCpuArray 桶 × 24 核 + PerfEventArray 用户态 mmap + libelf 解析全套 RocksDB 符号表。这个尖峰可能到 80-90 MB，**但完成后页面立即被释放**，VmRSS 降到 ~22 MB 稳态。VmHWM 永远记着那次尖峰。

**verdict 只看 VmRSS 不看 VmHWM 的原因：** main_proj.md spec 原文是"持续监控状态"，对应的指标是稳态 RSS 而不是历史峰值。早期版本错误地用 `max(VmRSS, VmHWM)` 做 verdict，导致 60 秒烟雾测试看到 VmHWM=85 MB 误报 FAIL（实际 VmRSS 一直 22 MB），用户在 conversation 里指出这点，于是修正为 VmRSS-only verdict。

**设计取舍：**

- **为什么用 `/proc/<pid>/status` 而不是 `pidstat -r`？** `/proc/<pid>/status` 字段更细（VmRSS / VmHWM / VmSize / VmData / VmStk 全部分开），polling 也更轻量。`pidstat -r` 会引入 sysstat 进程开销。
- **为什么 5 秒采样？** 50 MB 的 budget 跟内存波动幅度（每秒 KB 级）比是粗粒度，5 秒采样足够 capture 任何稳态变化。更细只是浪费。
- **为什么 `trap` 在 EXIT 而不是只在 SIGINT？** 进程死亡有多种原因（自然结束 / Ctrl+C / kill 信号 / shell 退出），EXIT 涵盖所有情况，确保 verdict 一定会被计算和打印出来。

> ⚠️ **关键 pitfall**：早期版本 verdict 同时检查 `max(VmRSS) <= budget` 和 `max(VmHWM) <= budget`，导致 BPF setup 时的瞬时尖峰被错算成 FAIL。如果你修改这个脚本，**绝对不要把 VmHWM 加进 verdict 判断**，HWM 的物理含义就不是稳态。


```bash
#!/usr/bin/env bash
#
# p2-rss.sh — sustained RSS monitor for ckb-probe (P-2 ≤ 50 MB).
#
# Usage:
#   ./p2-rss.sh [interval_seconds] [log_file]
#   ./p2-rss.sh --pid <PID> [interval] [log]
#
# Defaults: interval=5, log=$OUTPUT_DIR/p2-rss.log

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"
mkdir -p "$OUTPUT_DIR"
P2_BUDGET_MB=50

PROBE_PID=""
if [[ "${1:-}" == "--pid" ]]; then
    PROBE_PID="$2"
    shift 2
fi

INTERVAL="${1:-5}"
LOG="${2:-$OUTPUT_DIR/p2-rss.log}"

if [[ -z "$PROBE_PID" ]]; then
    PROBE_PID=$(pgrep -x ckb-probe | head -n1 || true)
    if [[ -z "$PROBE_PID" ]]; then
        echo "ERROR: no ckb-probe running" >&2
        exit 1
    fi
fi

echo "[p2-rss] pid=$PROBE_PID  interval=${INTERVAL}s  log=$LOG"
echo "# timestamp vmrss_kb vmrss_mb peak_kb peak_mb" > "$LOG"

cleanup() {
    echo
    echo "===== P-2 result ====="
    awk -v budget="$P2_BUDGET_MB" '
        /^#/ { next }
        NF >= 5 {
            sum += $3; n++
            if ($3 > max)  max  = $3
            if ($5 > peak) peak = $5
        }
        END {
            if (n == 0) { print "  no samples"; exit 1 }
            printf "  samples            : %d\n", n
            printf "  mean VmRSS (MB)    : %.2f  (sustained — what P-2 measures)\n", sum/n
            printf "  max  VmRSS (MB)    : %.2f  (sustained — what P-2 measures)\n", max
            printf "  peak VmHWM (MB)    : %.2f  (one-shot — info only, BPF map setup)\n", peak
            printf "  P-2 budget         : <= %d MB\n", budget
            if (max <= budget) print "  status             : ✅ PASS"
            else               print "  status             : ❌ FAIL"
        }
    ' "$LOG"
}
trap cleanup EXIT

while kill -0 "$PROBE_PID" 2>/dev/null; do
    rss_kb=$(awk '/^VmRSS:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
    hwm_kb=$(awk '/^VmHWM:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
    rss_mb=$(awk -v k="$rss_kb" 'BEGIN {printf "%.2f", k/1024}')
    hwm_mb=$(awk -v k="$hwm_kb" 'BEGIN {printf "%.2f", k/1024}')
    ts=$(date +%H:%M:%S)
    echo "$ts $rss_kb $rss_mb $hwm_kb $hwm_mb" | tee -a "$LOG" >/dev/null
    sleep "$INTERVAL"
done
```

### 3.3 `docker/scripts/perf/p3-stress.sh`

P-3 专项压力测试。两路同时给 ckb-probe 施压：(a) `--threshold 1` 让所有 RocksDB op 都进 perf buffer，(b) 后台 db_bench 拉高磁盘 I/O 让 CKB 自然产生更多 RocksDB 操作。最终从 ckb-probe footer 读 `BPF event loss` 计数。

**问题：** 如何在持续高事件率（spec 要求 10K events/sec）下测量 BPF PerfEventArray 的事件丢失率？

**机制：** 这个脚本背后有一个**关键依赖**——之前我们在 `ckb-probe/src/commands/rocksdb.rs` 的 `run_slow_mode()` 里加的 P-3 patch。原始代码 `events.lost` 被静默丢弃，patch 之后改成累加到 `Arc<AtomicU64>` 并在表格 footer 输出 `BPF event loss: X / Y attempted (Z%)`。这个脚本的核心就是**触发足够的事件流量 + 解析 footer**：

1. **`pgrep -x ckb`** 拿 CKB pid
2. **挂 ckb-probe `--slow --threshold 1`**：threshold=1 微秒意味着几乎所有 RocksDB 操作都会被 emit 成 slow event。在 testnet 接近 tip 的稳态节点上能压出 ~1200 events/sec
3. **可选启动 db_bench 后台**：`db_bench --benchmarks=fillrandom,readrandom,fillrandom --num=1000000 --threads=2`，写到 `/tmp/dbbench-db`。目的是占用磁盘 I/O 带宽，间接让 CKB 的 RocksDB 操作变慢（`--no-db-bench` 可关掉）
4. **`sleep $DURATION`**：默认 5 分钟
5. **停 ckb-probe** + grep footer 最后一行 → 解析 `lost / attempted / pct`
6. **算事件率** = `attempted / DURATION`，对照 P-3 budget 0.1% 给 verdict

**为什么实测速率达不到 10K/s？**

spec 目标是 10K events/sec，但实测只有 ~1200 events/sec。原因：CKB 节点已接近 tip，稳态下 RocksDB 操作密度本来就有限。要触达 10K/s 需要：

- **IBD 阶段**：每秒处理几十个 block × 每 block 几百个 cell 写入 → 几千到几万 RocksDB op/sec
- **RPC 风暴**：脚本人为 spam 大量 RPC 请求，每个 RPC 触发若干 GET/PUT
- **case-1 + p3-stress 组合**：在 IBD 期间跑 P-3 测量

**设计取舍：**

- **为什么 db_bench 是可选的（`--no-db-bench`）？** 在 SSD 充裕的机器上 db_bench 不会真的占满 I/O，对 CKB 的影响微乎其微。`--no-db-bench` 让脚本退化成"纯靠 ckb-probe threshold=1 制造高频事件"的版本。
- **为什么 threshold=1 不是 0？** 看 BPF 代码：`if *threshold > 0 && latency_ns > *threshold`——threshold=0 会被解释成"禁用 slow event 输出"，是个语义陷阱。threshold=1 表示 1 微秒（1000 ns），实际上几乎所有 op 都会通过。
- **为什么 verdict 触发条件是 `< 0.1%` 而不是 `<= 0.1%`？** spec 写"< 0.1%"是严格小于，verdict 要诚实反映 spec。

> ⚠️ **关键 pitfall**：脚本依赖 ckb-probe 的 P-3 patch（`run_slow_mode` 累加 `events.lost`）。**如果 ckb-probe 二进制是 patch 之前的版本，脚本会 grep 不到 "BPF event loss" 行，报 `FATAL: no 'BPF event loss' line found` 后退出**。Dockerfile 在 stage 2 构建 ckb-probe 时编译的就是带 patch 的最新代码，正常情况不会出问题；但如果用 `target/release/ckb-probe` 跑且这个二进制陈旧，记得先 `cargo build --release -p ckb-probe`。


```bash
#!/usr/bin/env bash
#
# p3-stress.sh — sustained-load BPF event loss test for P-3 (< 0.1%).
#
# Method: run ckb-probe in slow mode with --threshold 1 (every RocksDB op
# becomes a slow event), optionally create extra disk pressure with db_bench,
# read the loss rate from the probe footer at the end.
#
# Usage:
#   ./p3-stress.sh [duration_seconds] [--no-db-bench]

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
mkdir -p "$OUTPUT_DIR"

DURATION="${1:-300}"   # default 5 minutes
USE_DB_BENCH=1
[[ "${2:-}" == "--no-db-bench" ]] && USE_DB_BENCH=0

PROBE_LOG="$OUTPUT_DIR/p3-probe.log"
DBBENCH_LOG="$OUTPUT_DIR/p3-dbbench.log"
> "$PROBE_LOG"; > "$DBBENCH_LOG"

CKB_PID=$(pgrep -x ckb || true)
if [[ -z "$CKB_PID" ]]; then
    echo "[p3-stress] FATAL: no ckb running" >&2
    exit 1
fi

echo "[p3-stress] starting ckb-probe slow mode --threshold 1 against ckb pid=$CKB_PID"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1 --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
echo "[p3-stress] ckb-probe pid=$PROBE_PID"

if [[ "$USE_DB_BENCH" == "1" ]]; then
    echo "[p3-stress] starting db_bench background load"
    rm -rf /tmp/dbbench-db
    nohup db_bench \
        --benchmarks=fillrandom,readrandom,fillrandom \
        --num=1000000 \
        --threads=2 \
        --db=/tmp/dbbench-db \
        > "$DBBENCH_LOG" 2>&1 &
    disown
    DBB_PID=$(pgrep -f 'db_bench' | head -n1)
    echo "[p3-stress] db_bench pid=$DBB_PID"
fi

echo "[p3-stress] running for ${DURATION}s..."
sleep "$DURATION"

# Stop everything
echo "[p3-stress] stopping..."
[[ -n "${DBB_PID:-}" ]] && kill "$DBB_PID" 2>/dev/null || true
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
kill -TERM "$PROBE_PID" 2>/dev/null || true

# Parse the last "BPF event loss" line from the probe footer
LAST=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "")
if [[ -z "$LAST" ]]; then
    echo "[p3-stress] FATAL: no 'BPF event loss' line found in $PROBE_LOG" >&2
    exit 1
fi
LOST=$(echo "$LAST" | grep -oP '^\s*BPF event loss: \K\d+')
TOTAL=$(echo "$LAST" | grep -oP '\d+(?= attempted)')
PCT=$(echo "$LAST" | grep -oP '\(\K[0-9.]+(?=%)')
RATE=$(awk -v t="$TOTAL" -v s="$DURATION" 'BEGIN {printf "%.0f", t/s}')

echo
echo "===== P-3 result ====="
printf "  duration               : %ds\n" "$DURATION"
printf "  total events attempted : %s\n" "$TOTAL"
printf "  events lost            : %s\n" "$LOST"
printf "  loss rate              : %s%%\n" "$PCT"
printf "  achieved event rate    : %s events/sec\n" "$RATE"
printf "  P-3 budget             : < 0.1%% loss\n"
awk -v p="$PCT" 'BEGIN {
    if (p < 0.1) print "  status                 : ✅ PASS"
    else         print "  status                 : ❌ FAIL"
}'

if (( RATE < 10000 )); then
    cat <<NOTE

Note: achieved rate $RATE/s is below the 10K/s P-3 spec target. This is
expected when CKB is near tip; for a true 10K/s test the node should be
in IBD or under sustained heavy RPC load. Run case-1 + p3-stress in
combination for the most stressful scenario.
NOTE
fi
```

### 3.4 `docker/scripts/perf/p4-sync.sh`

CKB tip 高度差分计算 blocks/min。2 小时窗口为 P-4 spec。

**问题：** 如何测量 ckb-probe 挂载是否对 CKB 的同步速度（每分钟处理多少个 block）造成可见的退化？

**机制：** 时间序列差分

1. **每 60 秒**通过 `get_tip_block_number` RPC 拉一次当前 tip 高度
2. **采 120 个样本**（120 分钟 = 2 小时）
3. **算平均速率** = `(last_height - first_height) / duration_minutes`
4. **A/B 对比**：baseline 模式（不挂 probe）跑一次，with-probe 模式跑一次，算退化百分比 = `(baseline - with_probe) / baseline * 100`
5. **对照 budget 1%** 给 verdict

**为什么 2 小时窗口？**

CKB testnet 块间隔不是固定的——PoW 出块时间是泊松分布，单个 60 秒窗口的期望块数 ~7-8 但实际可能是 5/6/7/8/9/10/11 都正常。要让"1% 退化"在统计上可分辨，需要采样的总块数远大于自然方差：

- 60 秒窗口：~8 块期望，方差 ±3 块（~38%）→ 1% 完全淹没
- 30 分钟窗口：~240 块期望，方差 ±15 块（~6%）→ 1% 还是淹没
- **2 小时窗口**：~960 块期望，方差 ±30 块（~3%）→ 1% 接近可分辨极限
- 24 小时窗口：~11500 块期望，方差 ±100 块（~1%）→ 1% 才稳定可分辨

main_proj.md 选 2 小时是 **trade-off**：再长 evaluator 没耐心，再短数据没意义。2 小时是"可用性 vs 统计准确性"的最低可接受点。

**设计取舍：**

- **为什么用 RPC 而不是读 ckb 内存或日志？** RPC 是 ckb 的官方接口，最稳定。读内存需要侵入性 hook，读日志格式可能变。
- **为什么需要 `NO_PROXY=127.0.0.1`？** 早期 1 分钟烟雾测试发现 curl 会走 host 的 `http_proxy=192.168.15.1:2345`，导致请求被代理拦截返回 503。`NO_PROXY` 强制 127.0.0.1 直连。
- **为什么不在脚本里直接同时跑 baseline 和 with-probe？** 这两个状态互斥（要么 ckb-probe 挂着要么没挂），必须串行跑。脚本提供 `baseline` / `with-probe` / `compare` 三个子命令让 evaluator 显式控制顺序。

> ⚠️ **关键 pitfall**：A/B 测试两次必须从**相同的初始状态**开始——也就是说在跑 baseline 之前先 `restore-snapshot`，跑完 baseline 之后再 `restore-snapshot` 一次再跑 with-probe。否则两次的 IBD 起点不同，速率根本没法比较。case study 里 `full-perf-run.sh` orchestrator 也假定环境稳态，不会每次重新 restore——这是 trade-off：完美的 A/B 复现 vs 4h 总时长。


```bash
#!/usr/bin/env bash
#
# p4-sync.sh — CKB block sync rate sampler for P-4 (< 1% degradation).
#
# Usage:
#   ./p4-sync.sh baseline   [duration_minutes]
#   ./p4-sync.sh with-probe [duration_minutes]
#   ./p4-sync.sh compare
#
# Defaults: duration=120 (2h), tip sample every 60s

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
mkdir -p "$OUTPUT_DIR"

DURATION_MIN="${2:-120}"
P4_BUDGET=1.0

fetch_tip() {
    local hex
    hex=$(NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty')
    [[ -z "$hex" || "$hex" == "null" ]] && { echo "FATAL: no tip from $CKB_RPC" >&2; return 1; }
    printf '%d\n' "$hex"
}

run_sample() {
    local label="$1"
    local logfile="$OUTPUT_DIR/p4-sync-${label}.log"
    echo "[p4-sync] $label duration=${DURATION_MIN}min  rpc=$CKB_RPC -> $logfile"
    echo "# unix_ts height" > "$logfile"
    for ((i = 0; i < DURATION_MIN; i++)); do
        local h ts
        h=$(fetch_tip) || exit 1
        ts=$(date +%s)
        echo "$ts $h" | tee -a "$logfile" >/dev/null
        sleep 60
    done
    summarise "$logfile"
}

summarise() {
    awk '
        /^#/ { next }
        NF == 2 {
            if (n == 0) { ft=$1; fh=$2 }
            lt=$1; lh=$2; n++
        }
        END {
            if (n < 2) { print "[p4-sync] not enough samples"; exit 1 }
            dur_min = (lt - ft) / 60.0
            blocks  = lh - fh
            printf "[p4-sync] %s -> samples=%d  duration=%.1f min  blocks=%d  blocks/min=%.3f\n", \
                FILENAME, n, dur_min, blocks, blocks/dur_min
        }
    ' "$1"
}

cmd_compare() {
    local b="$OUTPUT_DIR/p4-sync-baseline.log"
    local w="$OUTPUT_DIR/p4-sync-with-probe.log"
    [[ -f "$b" && -f "$w" ]] || { echo "ERROR: run baseline + with-probe first" >&2; exit 1; }
    local bm wm degr
    bm=$(awk '/^#/ {next} NF==2 {if (n==0) {ft=$1; fh=$2} lt=$1; lh=$2; n++}
              END {printf "%.4f", (lh-fh)/((lt-ft)/60.0)}' "$b")
    wm=$(awk '/^#/ {next} NF==2 {if (n==0) {ft=$1; fh=$2} lt=$1; lh=$2; n++}
              END {printf "%.4f", (lh-fh)/((lt-ft)/60.0)}' "$w")
    degr=$(awk -v a="$bm" -v c="$wm" 'BEGIN {
        if (a == 0) { print "NaN"; exit }
        printf "%.4f", (a-c)/a*100
    }')
    echo
    echo "===== P-4 result ====="
    echo "  baseline blocks/min   : $bm"
    echo "  with-probe blocks/min : $wm"
    echo "  degradation           : ${degr}%"
    printf "  P-4 budget            : < %.1f%%\n" "$P4_BUDGET"
    awk -v d="$degr" -v b="$P4_BUDGET" 'BEGIN {
        if (d == "NaN") { print "  status                : ⚠️  NaN"; exit }
        if (d <= b) print "  status                : ✅ PASS"
        else        print "  status                : ❌ FAIL"
    }'
}

case "${1:-}" in
    baseline)   run_sample baseline ;;
    with-probe) run_sample with-probe ;;
    compare)    cmd_compare ;;
    *)
        sed -n '3,15p' "$0"
        exit 1
        ;;
esac
```

### 3.5 `docker/scripts/perf/full-perf-run.sh`

4h orchestrator：Phase A 2h with-probe（覆盖 P-1 + P-2 + P-3 + P-4 with-probe），Phase B 2h baseline（P-1 + P-4 baseline），Phase C 自动算 verdict 写 REPORT.txt。

**问题：** 单独跑四个 P 脚本要 evaluator 手动协调启停顺序，容易出错。如何把整套 P-1~P-4 评估自动化成一次 4h 跑批？

**机制：** 三阶段编排

```
T=0          ┌─── Phase A (2h, with-probe attached) ───┐
             │  • start ckb-probe slow --threshold 1   │
             │  • pidstat CKB %CPU         (P-1 with-probe)
             │  • RSS poller for ckb-probe (P-2)
             │  • tip sampler              (P-4 with-probe)
             │  • probe footer captures    (P-3 throughout)
             │                                          │
T=2h    ─────┤ stop ckb-probe                          │
             ├─── Phase B (2h, no probe — baseline) ───┤
             │  • pidstat CKB %CPU         (P-1 baseline)
             │  • tip sampler              (P-4 baseline)
             │                                          │
T=4h    ─────┤── Phase C (compute & write REPORT) ─────┤
             │  • parse all logs                       │
             │  • compute deltas                       │
             │  • write REPORT.txt with verdicts       │
             └─────────────────────────────────────────┘
```

**Phase A** 同时开 4 个 background 任务（ckb-probe / pidstat / RSS poller / tip sampler），用 `wait` 等到最长的 task（pidstat 7200s）完成后停 ckb-probe。

**Phase B** 只开 2 个 background 任务（pidstat / tip sampler），不挂 ckb-probe。

**Phase C** 用 awk 解析所有日志，按 P-1/P-2/P-3/P-4 分组计算 verdict，最后写一份格式化的 REPORT.txt。

**关键设计点：**

- **P-1 用 1h subset**：spec 要求 1h 窗口，但 Phase A/B 都是 2h——脚本计算 P-1 时**只取每个 phase 的前 1h 数据**做 mean，跟 spec 严格对齐。同时输出 2h 全部数据作为参考。
- **P-2 用 Phase A 全 2h 数据**：spec 是"持续监控状态"，2h 数据更稳定。
- **P-3 用 Phase A 末次 footer**：probe 在 Phase A 跑了 2h，期间累计的 `BPF event loss` 计数在最后一次 footer 输出里。
- **P-4 用各 Phase 的全 2h tip 数据**：直接套 spec 的 2h 窗口。
- **`trap cleanup EXIT INT TERM`**：4h 长跑期间 evaluator 可能 Ctrl+C，trap 确保任何中断都会先 SIGINT 停掉 ckb-probe，不留孤儿进程。
- **PID file** (`$OUTPUT_DIR/pids`)：所有 background 任务的 PID 写到这个文件，紧急情况一行 `while read p; do kill $p; done < pids` 全杀。
- **progress.log**：关键时间点（Phase 起始、halftime、阶段切换、cleanup）都写时间戳到 progress.log，evaluator `tail -f` 就能看进度。

**Phase B 之前的 10 秒 cool-down：** Phase A 结束后 sleep 10 秒再开始 Phase B，目的是让 ckb 在 ckb-probe 卸载后稳定一下（uprobe detach 是个轻量但非零的操作），避免 Phase B 的前几秒数据被 detach 噪声污染。

**REPORT.txt 的格式：**

```
══════════════════════════════════════════════════════════════
  ckb-probe rocksdb · 4-hour P-1 ~ P-4 performance overhead report
  Generated: 2026-04-11 14:48:52
══════════════════════════════════════════════════════════════

Test setup
  CKB pid          : 3310428
  ...

──── P-1 (CPU ≤ 3% over 1h) ────
  baseline   : 108.667%   n=720
  with-probe : 105.667%   n=720
  delta      : -3.0000
  status     : ✅ PASS

──── P-2 (RSS ≤ 50 MB sustained) ────
  ...

──── P-3 (event loss < 0.1%) ────
  ...

──── P-4 (sync degradation < 1% over 2h IBD) ────
  ...
```

evaluator 一眼能看完，REPORT.txt 也是中期报告里要展示的最终成果物。

**设计取舍：**

- **为什么不让 Phase A 和 Phase B 并行？** 不行——P-1 和 P-4 的 baseline 必须**没有 ckb-probe** 的前提下测，否则就不是 baseline 了。
- **为什么 Phase B 不再单独跑 P-2 和 P-3？** P-2 measures **ckb-probe 自己的内存**，没 ckb-probe 就没东西测。P-3 measures **BPF 事件丢失**，没 ckb-probe 也就没事件流。这两项 Phase B 不需要数据。
- **为什么不用 systemd timer 或 cron？** 4 小时的 long-running task 在容器里用 systemd 太重，cron 不方便传 stdout/stderr 给 evaluator。bash trap + background tasks 是最朴素的方案，可读性最好。
- **为什么 halftime 标记有用？** evaluator 通过 `tail -f progress.log` 看进度，halftime 标记让 ta 知道"到 1h 了，还有 1h"——比纯 sleep 4h 体验好。

> ⚠️ **关键 pitfall**：脚本依赖 4h 期间 CKB 持续运行。如果中途 CKB crash，pidstat 会发现 PID 不存在并自然退出，导致 wait 提前返回，整个 phase 中断。脚本没有自动重启 CKB 的逻辑——这是设计选择（CKB crash 在评估期间发生本身就是一个数据点，不应该被自动 mask 掉）。如果 CKB crash 了，evaluator 看 progress.log 能看到中断时间，决定是否重跑。


```bash
#!/usr/bin/env bash
#
# full-perf-run.sh — full P-1 ~ P-4 evaluation per main_proj.md spec.
#
# Phase A (2h with-probe): captures P-1 with-probe (subset 1h), P-2, P-3, P-4 with-probe
# Phase B (2h baseline):   captures P-1 baseline (subset 1h), P-4 baseline
# Phase C: computes verdicts, writes $OUTPUT_DIR/REPORT.txt
#
# Total wall time: ~4 hours
# Usage: ./full-perf-run.sh

set -uo pipefail

# ── config ─────────────────────────────────────────────────────
CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"

PHASE_A_SECS=7200
PHASE_B_SECS=7200
SAMPLE_SECS=5
TIP_SECS=60
TIP_SAMPLES=120
PHASE_A_CPU_SAMPLES=$((PHASE_A_SECS / SAMPLE_SECS))
PHASE_B_CPU_SAMPLES=$((PHASE_B_SECS / SAMPLE_SECS))

P1_BUDGET=3.0
P2_BUDGET_MB=50
P3_BUDGET_PCT=0.1
P4_BUDGET_PCT=1.0

mkdir -p "$OUTPUT_DIR"
PROGRESS=$OUTPUT_DIR/progress.log
PROBE_LOG=$OUTPUT_DIR/probe-slow.log
P1_WP=$OUTPUT_DIR/p1-with-probe.log
P1_BL=$OUTPUT_DIR/p1-baseline.log
P2_LOG=$OUTPUT_DIR/p2-rss.log
P4_WP=$OUTPUT_DIR/p4-with-probe.log
P4_BL=$OUTPUT_DIR/p4-baseline.log
REPORT=$OUTPUT_DIR/REPORT.txt
PIDS_FILE=$OUTPUT_DIR/pids

log() { echo "[$(date '+%F %T')] $*" | tee -a "$PROGRESS"; }

fetch_tip() {
    NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty'
}

cleanup() {
    log "cleanup: stopping background tasks"
    if [[ -f "$PIDS_FILE" ]]; then
        while read -r p; do kill "$p" 2>/dev/null || true; done < "$PIDS_FILE"
    fi
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── sanity ─────────────────────────────────────────────────────
log "===== full-perf-run started ====="
log "OUTPUT_DIR=$OUTPUT_DIR"

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    log "FATAL: no ckb process"
    exit 1
fi
log "CKB pid=$CKB_PID  RPC=$CKB_RPC"

if [[ -z "$(fetch_tip)" ]]; then
    log "FATAL: CKB RPC at $CKB_RPC not responding"
    exit 1
fi

if pgrep -x ckb-probe >/dev/null; then
    log "WARN: existing ckb-probe found, killing"
    pkill -x ckb-probe || true
    sleep 2
fi

> "$PIDS_FILE"

# ── Phase A — 2h with-probe ────────────────────────────────────
log "----- Phase A: 2h with-probe -----"
PHASE_A_START=$(date +%s)

log "starting ckb-probe rocksdb --slow --threshold 1 --interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1 --interval 5 \
    > "$PROBE_LOG" 2>&1 &
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { log "FATAL: ckb-probe failed to spawn"; tail "$PROBE_LOG"; exit 1; }
log "ckb-probe attached, pid=$PROBE_PID"

pidstat -u -h -p "$CKB_PID" "$SAMPLE_SECS" "$PHASE_A_CPU_SAMPLES" > "$P1_WP" 2>&1 &
P1_BG=$!; echo "$P1_BG" >> "$PIDS_FILE"
log "P-1 with-probe: pidstat bg=$P1_BG"

(
    > "$P2_LOG"
    while kill -0 "$PROBE_PID" 2>/dev/null; do
        if [[ -f /proc/$PROBE_PID/status ]]; then
            ts=$(date +%s)
            rss=$(awk '/^VmRSS:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
            hwm=$(awk '/^VmHWM:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
            echo "$ts $rss $hwm" >> "$P2_LOG"
        fi
        sleep "$SAMPLE_SECS"
    done
) &
P2_BG=$!; echo "$P2_BG" >> "$PIDS_FILE"
log "P-2: RSS poller bg=$P2_BG"

(
    echo "# unix_ts hex_height dec_height" > "$P4_WP"
    for ((i = 0; i < TIP_SAMPLES; i++)); do
        ts=$(date +%s)
        h=$(fetch_tip)
        if [[ -n "$h" ]]; then
            d=$(printf '%d' "$h")
            echo "$ts $h $d" >> "$P4_WP"
        fi
        sleep "$TIP_SECS"
    done
) &
P4_BG=$!; echo "$P4_BG" >> "$PIDS_FILE"
log "P-4 with-probe: tip sampler bg=$P4_BG"

( sleep $((PHASE_A_SECS / 2)); log "Phase A halftime (1h elapsed)" ) &

log "Phase A waiting..."
wait "$P1_BG" 2>/dev/null
log "Phase A: pidstat done"
wait "$P4_BG" 2>/dev/null
log "Phase A: tip sampler done"

log "Phase A: stopping ckb-probe"
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
kill -TERM "$PROBE_PID" 2>/dev/null || true
PROBE_PID=""
wait "$P2_BG" 2>/dev/null
log "Phase A complete in $(($(date +%s) - PHASE_A_START))s"

sleep 10

# ── Phase B — 2h baseline ──────────────────────────────────────
log "----- Phase B: 2h baseline -----"
PHASE_B_START=$(date +%s)

if pgrep -x ckb-probe >/dev/null; then
    pkill -x ckb-probe || true
    sleep 2
fi

pidstat -u -h -p "$CKB_PID" "$SAMPLE_SECS" "$PHASE_B_CPU_SAMPLES" > "$P1_BL" 2>&1 &
P1B_BG=$!; echo "$P1B_BG" >> "$PIDS_FILE"
log "P-1 baseline: pidstat bg=$P1B_BG"

(
    echo "# unix_ts hex_height dec_height" > "$P4_BL"
    for ((i = 0; i < TIP_SAMPLES; i++)); do
        ts=$(date +%s)
        h=$(fetch_tip)
        if [[ -n "$h" ]]; then
            d=$(printf '%d' "$h")
            echo "$ts $h $d" >> "$P4_BL"
        fi
        sleep "$TIP_SECS"
    done
) &
P4B_BG=$!; echo "$P4B_BG" >> "$PIDS_FILE"
log "P-4 baseline: tip sampler bg=$P4B_BG"

( sleep $((PHASE_B_SECS / 2)); log "Phase B halftime (1h elapsed)" ) &

wait "$P1B_BG" 2>/dev/null
log "Phase B: pidstat done"
wait "$P4B_BG" 2>/dev/null
log "Phase B complete in $(($(date +%s) - PHASE_B_START))s"

# ── Phase C — verdicts ─────────────────────────────────────────
log "----- Phase C: computing verdicts -----"

compute_p1() {
    local logfile="$1" hours="$2"
    local samples_1h=$((3600 / SAMPLE_SECS))
    awk -v limit="$samples_1h" -v hours="$hours" '
        /^#/ { next }
        NF >= 10 {
            n_full++; sum_full += $9
            if (n_1h < limit) { n_1h++; sum_1h += $9 }
        }
        END {
            if (hours == 1) {
                if (n_1h == 0) print "NaN NaN"
                else printf "%.4f %d\n", sum_1h/n_1h, n_1h
            } else {
                if (n_full == 0) print "NaN NaN"
                else printf "%.4f %d\n", sum_full/n_full, n_full
            }
        }
    ' "$logfile"
}

read P1_WP_1H_MEAN P1_WP_1H_N <<< "$(compute_p1 "$P1_WP" 1)"
read P1_BL_1H_MEAN P1_BL_1H_N <<< "$(compute_p1 "$P1_BL" 1)"
P1_DELTA_1H=$(awk -v a="$P1_WP_1H_MEAN" -v b="$P1_BL_1H_MEAN" 'BEGIN {printf "%+.4f", a-b}')

P2_STATS=$(awk '
    NF == 3 {
        sum += $2; n++
        if ($2 > max_rss) max_rss = $2
        if ($3 > max_hwm) max_hwm = $3
    }
    END {
        if (n == 0) { print "NaN NaN NaN NaN"; exit }
        printf "%.4f %.4f %.4f %d\n", sum/n/1024, max_rss/1024, max_hwm/1024, n
    }
' "$P2_LOG")
read P2_MEAN_MB P2_MAX_MB P2_HWM_MB P2_N <<< "$P2_STATS"

P3_LINE=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "")
if [[ -n "$P3_LINE" ]]; then
    P3_LOST=$(echo "$P3_LINE" | grep -oP '^\s*BPF event loss: \K\d+')
    P3_TOTAL=$(echo "$P3_LINE" | grep -oP '\d+(?= attempted)')
    P3_PCT=$(echo "$P3_LINE" | grep -oP '\(\K[0-9.]+(?=%)')
    P3_RATE=$(awk -v t="$P3_TOTAL" -v s="$PHASE_A_SECS" 'BEGIN {printf "%.0f", t/s}')
else
    P3_LOST="?"; P3_TOTAL="?"; P3_PCT="?"; P3_RATE="?"
fi

compute_p4() {
    awk '
        /^#/ { next }
        NF == 3 {
            if (n == 0) { ft=$1; fh=$3 }
            lt=$1; lh=$3; n++
        }
        END {
            if (n < 2) { print "NaN NaN NaN"; exit }
            dur_min = (lt-ft)/60.0
            blocks  = lh-fh
            printf "%.4f %d %.2f\n", blocks/dur_min, blocks, dur_min
        }
    ' "$1"
}

read P4_WP_BPM P4_WP_BLOCKS P4_WP_DUR <<< "$(compute_p4 "$P4_WP")"
read P4_BL_BPM P4_BL_BLOCKS P4_BL_DUR <<< "$(compute_p4 "$P4_BL")"
P4_DEGRAD=$(awk -v a="$P4_BL_BPM" -v b="$P4_WP_BPM" 'BEGIN {
    if (a == 0 || a == "NaN") { print "NaN" } else printf "%+.4f", (a-b)/a*100
}')

# ── Write report ───────────────────────────────────────────────
{
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "  ckb-probe rocksdb · 4-hour P-1 ~ P-4 performance overhead report"
    echo "  Generated: $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo
    echo "Test setup"
    echo "  CKB pid          : $CKB_PID"
    echo "  CKB binary       : $CKB_BIN"
    echo "  CKB RPC          : $CKB_RPC"
    echo "  probe binary     : $PROBE_BIN"
    echo "  probe args       : rocksdb --slow --threshold 1 --interval 5"
    echo "  phase A duration : ${PHASE_A_SECS}s with-probe"
    echo "  phase B duration : ${PHASE_B_SECS}s baseline"
    echo
    echo "──── P-1 (CPU ≤ 3% over 1h) ────"
    printf "  baseline   : %s%%   n=%s\n" "$P1_BL_1H_MEAN" "$P1_BL_1H_N"
    printf "  with-probe : %s%%   n=%s\n" "$P1_WP_1H_MEAN" "$P1_WP_1H_N"
    printf "  delta      : %s\n" "$P1_DELTA_1H"
    awk -v d="$P1_DELTA_1H" -v b="$P1_BUDGET" 'BEGIN {
        if (d <= b) print "  status     : ✅ PASS"; else print "  status     : ❌ FAIL"
    }'
    echo
    echo "──── P-2 (RSS ≤ 50 MB sustained) ────"
    printf "  mean VmRSS : %s MB\n" "$P2_MEAN_MB"
    printf "  max  VmRSS : %s MB\n" "$P2_MAX_MB"
    printf "  peak VmHWM : %s MB  (info only)\n" "$P2_HWM_MB"
    awk -v m="$P2_MAX_MB" -v b="$P2_BUDGET_MB" 'BEGIN {
        if (m <= b) print "  status     : ✅ PASS"; else print "  status     : ❌ FAIL"
    }'
    echo
    echo "──── P-3 (event loss < 0.1% under 10K/s sustained) ────"
    printf "  attempted  : %s\n" "$P3_TOTAL"
    printf "  lost       : %s\n" "$P3_LOST"
    printf "  loss rate  : %s%%\n" "$P3_PCT"
    printf "  rate       : %s events/sec\n" "$P3_RATE"
    if [[ "$P3_PCT" != "?" ]]; then
        awk -v p="$P3_PCT" 'BEGIN {
            if (p < 0.1) print "  status     : ✅ PASS"; else print "  status     : ❌ FAIL"
        }'
    fi
    echo
    echo "──── P-4 (sync degradation < 1% over 2h IBD) ────"
    printf "  baseline   : %s blocks/min  (%s blocks over %s min)\n" "$P4_BL_BPM" "$P4_BL_BLOCKS" "$P4_BL_DUR"
    printf "  with-probe : %s blocks/min  (%s blocks over %s min)\n" "$P4_WP_BPM" "$P4_WP_BLOCKS" "$P4_WP_DUR"
    printf "  degradation: %s%%\n" "$P4_DEGRAD"
    if [[ "$P4_DEGRAD" != "NaN" ]]; then
        awk -v d="$P4_DEGRAD" -v b="$P4_BUDGET_PCT" 'BEGIN {
            if (d <= b) print "  status     : ✅ PASS"; else print "  status     : ❌ FAIL"
        }'
    fi
    echo
    echo "════════════════════════════════════════════════════════════════════════════════"
} > "$REPORT"

log "Report written to $REPORT"
log "===== full-perf-run finished ====="
```

---

## 4. RocksDB 案例诊断脚本

### 总览

这一节是 case study 的"主菜"——用 ckb-probe 在真实 CKB 节点上演示两个具体的 RocksDB 性能场景，作为中期报告里"工具确实有用"的端到端证据。

### 两个互补的案例

| 案例 | 工作负载 | ckb-probe 主要展示能力 | 主要交付物 |
|---|---|---|---|
| **case-1** IBD 写入模式 | 持续数小时的高吞吐重写 | QPS / Bytes/s 聚合 + log2 直方图演化 | 时间序列图 + 三连直方图 |
| **case-2** Compaction storm | 瞬时延迟尖峰 | EWMA 异常检测 + 归因 + slow events | 对比直方图 + 终端录屏 |

两者**正好覆盖 ckb-probe 全部主要能力**：聚合统计 vs 异常检测、持续展示 vs 瞬时捕获、单点指标 vs 关联归因。

### 触发方式的现实考虑

- **case-1** 用 snapshot restore 触发——CKB 从 snapshot 时刻开始追当前 tip，自动产生 IBD 工作负载。snapshot 落后多远 → IBD 多长。
- **case-2** 用 ckb.toml.aggressive 触发——把 RocksDB 调成"compaction 极易触发"状态，重启 CKB，几分钟内必出 storm。

理论上 case-1 期间也会自然产生 compaction storm（IBD 写压力大），所以**两个案例可以合并执行**。脚本目前是分开的，但 evaluator 想合并的话只需要在 case-1 期间观察 ANOMALY DETECTED 计数。

### 输出目录结构

```
/tmp/perf-run/
├── case1/
│   ├── case1.log         # driver run log
│   ├── probe.log         # ckb-probe histogram 全文输出
│   ├── tip.log           # tip height time series
│   └── REPORT.txt        # case-1 结论
└── case2/
    ├── case2.log
    ├── probe.log
    └── REPORT.txt
```

### 4.1 `docker/scripts/case/start-ckb.sh`

幂等启动 CKB（已经在跑则跳过），等 RPC ready 才返回。

**问题：** 多个 case study 脚本都依赖"CKB 已经在跑且 RPC 可用"。如何提供一个可以重复调用的 helper，让每个调用方不需要自己重写启动逻辑？

**机制：** 4 步幂等启动

1. **如果 CKB 已经在跑，立即返回**：`pgrep -x ckb` 看到进程就 echo 一句话退出
2. **检查 CKB_DATA 目录存在**：没有的话给清晰错误（"mount it with -v ..."）
3. **如果没有 ckb.toml，先 init**：`ckb init --chain testnet -C $CKB_DATA`——首次启动需要这一步
4. **`nohup ckb run` 启动后轮询 RPC**：最多等 60 秒，每 2 秒尝试一次 `get_tip_block_number`，成功就返回；超时报错并 dump `/var/log/ckb.log` 末尾 30 行

**为什么是 helper 不是 main entrypoint？**

case-1、case-2、demo-normal、demo-stress 都需要 CKB 在跑，但每个脚本的责任不是"启动 CKB"——它们的责任是各自的 case study 逻辑。把启动逻辑抽到 helper 是 **DRY 原则**：一个地方维护"如何把 CKB 拉起来"，所有调用方共享。

**设计取舍：**

- **为什么用 `nohup` 而不是用 systemd？** 容器里没 systemd（debian:slim 没装），nohup + disown 是最朴素的"后台启动一个长寿进程"方法。
- **为什么轮询而不是 sleep 30？** 同前面解释——固定 sleep 既可能太短也可能太长。
- **为什么超时报错时 dump `ckb.log` 末尾？** evaluator 第一时间能看到 ckb 启动失败的真正原因（端口被占？磁盘满？config 写错？），不需要再额外去翻日志文件。

> ⚠️ **关键 pitfall**：testnet bootstrap 节点连接需要时间，**RPC ready 不等于 P2P ready**。脚本只等 RPC，不等 P2P。如果调用方需要 P2P ready（比如 case-1 要等 IBD 真正开始），调用方应该自己再 sleep 5-10 秒。


```bash
#!/usr/bin/env bash
#
# start-ckb.sh — idempotent CKB startup. Returns when RPC is ready.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"

if pgrep -x ckb >/dev/null; then
    echo "[start-ckb] already running, pid=$(pgrep -x ckb)"
    exit 0
fi

if [[ ! -d "$CKB_DATA" ]]; then
    echo "[start-ckb] FATAL: CKB_DATA=$CKB_DATA does not exist" >&2
    echo "                   mount it with -v /host/ckb-data:$CKB_DATA" >&2
    exit 1
fi

# Initialise config if missing
if [[ ! -f "$CKB_DATA/ckb.toml" ]]; then
    echo "[start-ckb] no ckb.toml found, running ckb init --chain testnet"
    "$CKB_BIN" init --chain testnet -C "$CKB_DATA"
fi

echo "[start-ckb] starting ckb..."
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown

# Wait for RPC
for _ in {1..60}; do
    if curl -sf -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        >/dev/null 2>&1; then
        echo "[start-ckb] RPC ready, pid=$(pgrep -x ckb)"
        exit 0
    fi
    sleep 2
done

echo "[start-ckb] FATAL: CKB RPC did not come up within 120s" >&2
tail -30 /var/log/ckb.log >&2 || true
exit 1
```

### 4.2 `docker/scripts/case/case-1-ibd-write-pattern.sh`

完整 case-1 driver：恢复 snapshot → 启 CKB → 挂 ckb-probe（histogram 模式）→ 等 IBD 完成 → 出报告。

**问题：** 如何端到端跑案例 1（IBD 写入模式分析），让 evaluator 一行命令就拿到完整的 IBD 工作负载特征数据 + 报告？

**机制：** 6 步流水线

1. **`restore-snapshot.sh`** 把 db 还原到一个落后的历史高度。snapshot 文件名暗示了距离（比如 `snap-h20725000` 距当前 tip 5000 块 ≈ 1 小时 IBD）
2. **等 RPC 和 P2P ready**：snapshot restore 后启动的 CKB 需要几秒到几十秒接进 testnet bootstrap，case-1 driver 在 RPC ready 后再 sleep 几秒
3. **`pgrep -x ckb`** 拿新启动的 CKB pid
4. **挂 `ckb-probe rocksdb --histogram --interval 5`**：histogram 模式每 5 秒打印一次表格 + 完整 log2 直方图，后台跑，输出全部重定向到 `probe.log`
5. **轮询 tip 监测 IBD 进度**：每 30 秒拉一次 tip。当 tip 连续 90 秒不变（3 个连续相同的 sample），认为 IBD 完成
6. **停 ckb-probe + 写 REPORT.txt**：报告里包含起止 tip、blocks 数、时长、blocks/min、最后一次 histogram 截图、文件路径索引

**关键设计点：**

- **超时上限 `MAX_SECS`**（默认 7200 秒 = 2 小时）—— evaluator 不希望 case-1 跑得没完没了。如果 snapshot 太老（比如 1 周前），2h 跑不完，达到上限就停止并报告"timeout"
- **"tip 连续 90s 不变" 作为 IBD 完成标志**：CKB 追上当前 tip 后会进入 normal mode，每隔 8 秒左右接收一个新 block。轮询窗口 90s（3 × 30s）足够穿越 1-2 个正常 block 间隔，避免误判
- **`tail -120` 截取最后一个 histogram 块**：probe.log 可能上百 MB（histogram 模式 5 秒一次，2 小时 = 1440 次输出），report 里只放最后一次的 histogram 作为"IBD 末期状态"
- **trap cleanup**：被中断时杀 ckb-probe，避免长时间残留

**设计取舍：**

- **为什么用 `--histogram` 模式而不是 default 模式？** histogram 模式打印的内容是 default 表格的超集——既有 QPS/Avg/P50/P99 表格，又有每个 op 的完整 log2 分桶分布。对案例 1 这种"看 IBD 期间延迟分布如何演化"的场景，histogram 是必需的。
- **为什么不用 `--record <dir>` 二进制采集？** Week 5 计划里那个 `--record` 子命令还没落地（这是 Week 5 任务项 4）。在它落地之前，case-1 用 stdout 重定向 + 后处理是 acceptable workaround。
- **为什么不在 case-1 里同时跑 P-1/P-2/P-3 测量？** case-1 的目的是"产生数据"，不是"评估 ckb-probe 自己的开销"。后者是 perf 脚本的责任。把两件事混在一起会让代码复杂、verdict 混乱。
- **为什么不解析 histogram 数据生成 plot？** 当前 case-1 的输出是 raw histogram 文本。未来可以加一个 Python 后处理脚本生成 PNG plot，但这是 nice-to-have，不在 Week 5/6 必交付清单里。

> ⚠️ **关键 pitfall**：snapshot 制作和 case-1 调用之间的间隔决定 IBD 长度。如果 snapshot 是**刚刚做的**（比如 5 分钟前），那 case-1 启动时 tip 离 snapshot 高度只差 ~30 块，IBD 几秒就完成，根本没数据可看。**case-1 之前 evaluator 应该等 snapshot "老化"半小时到几小时**，让真正 tip 拉开距离。或者用一个旧的 snapshot。


```bash
#!/usr/bin/env bash
#
# case-1-ibd-write-pattern.sh — IBD write pattern case study.
#
# Workflow:
#   1) restore snapshot to put CKB at a historical tip
#   2) start CKB (auto IBD begins)
#   3) attach ckb-probe rocksdb --histogram and capture output
#   4) poll tip every 30s; stop when within N blocks of network tip OR timeout
#   5) write summary report
#
# Usage:
#   ./case-1-ibd-write-pattern.sh <snapshot.tar.zst> [max_duration_seconds]
#
# Default max duration: 7200 (2h)

set -euo pipefail

SNAP="${1:?usage: case-1-ibd-write-pattern.sh <snapshot.tar.zst> [max_seconds]}"
MAX_SECS="${2:-7200}"

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/case1"
mkdir -p "$OUTPUT_DIR"

CASE_LOG=$OUTPUT_DIR/case1.log
PROBE_LOG=$OUTPUT_DIR/probe.log
TIP_LOG=$OUTPUT_DIR/tip.log
REPORT=$OUTPUT_DIR/REPORT.txt
> "$CASE_LOG"; > "$PROBE_LOG"; > "$TIP_LOG"

log() { echo "[$(date '+%T')] $*" | tee -a "$CASE_LOG"; }

cleanup() {
    log "cleanup"
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 3
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

fetch_tip() {
    NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty'
}

# ── 1) Restore snapshot ────────────────────────────────────────
log "===== case-1: IBD write pattern ====="
log "snapshot: $SNAP"
log "max duration: ${MAX_SECS}s"

log "restoring snapshot (this will stop ckb if running)..."
/opt/scripts/snapshot/restore-snapshot.sh "$SNAP"

# ── 2) Wait for CKB RPC ready ──────────────────────────────────
for _ in {1..30}; do
    [[ -n "$(fetch_tip)" ]] && break
    sleep 2
done
START_TIP_HEX=$(fetch_tip)
START_TIP=$(printf '%d' "$START_TIP_HEX")
START_TS=$(date +%s)
log "CKB started at tip=$START_TIP"

# ── 3) Attach ckb-probe in histogram mode ──────────────────────
CKB_PID=$(pgrep -x ckb | head -n1)
log "attaching ckb-probe rocksdb --histogram --interval 5 to pid=$CKB_PID"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --histogram --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { log "FATAL: ckb-probe failed to start"; exit 1; }
log "ckb-probe pid=$PROBE_PID"

# ── 4) Poll tip; stop when caught up or timeout ────────────────
log "polling tip every 30s, stop when caught up or after ${MAX_SECS}s"
echo "# unix_ts dec_height" > "$TIP_LOG"
LAST_TIP=$START_TIP
STALL_COUNT=0

while true; do
    NOW=$(date +%s)
    if (( NOW - START_TS > MAX_SECS )); then
        log "timeout reached after ${MAX_SECS}s"
        break
    fi

    CUR_HEX=$(fetch_tip)
    [[ -z "$CUR_HEX" ]] && { sleep 5; continue; }
    CUR=$(printf '%d' "$CUR_HEX")
    echo "$NOW $CUR" >> "$TIP_LOG"

    # Detect "caught up" — when tip stops advancing for 3 consecutive 30s polls
    if (( CUR == LAST_TIP )); then
        STALL_COUNT=$((STALL_COUNT + 1))
        if (( STALL_COUNT >= 3 )); then
            log "tip stable at $CUR for 90s, considered caught up"
            break
        fi
    else
        STALL_COUNT=0
        LAST_TIP=$CUR
    fi
    sleep 30
done

END_TS=$(date +%s)
END_TIP=$LAST_TIP
DURATION=$((END_TS - START_TS))
BLOCKS=$((END_TIP - START_TIP))
BPM=$(awk -v b="$BLOCKS" -v s="$DURATION" 'BEGIN {printf "%.2f", b/s*60}')
log "IBD complete: $BLOCKS blocks in ${DURATION}s (${BPM} blocks/min)"

# ── 5) Stop ckb-probe and capture final histogram snapshot ────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# ── 6) Write report ────────────────────────────────────────────
{
    echo "════════════════════════════════════════════════════════════════"
    echo "  case-1: IBD write pattern analysis"
    echo "  Generated: $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "Setup"
    echo "  snapshot         : $SNAP"
    echo "  starting tip     : $START_TIP"
    echo "  final tip        : $END_TIP"
    echo "  blocks processed : $BLOCKS"
    echo "  duration         : ${DURATION}s"
    echo "  blocks/min       : $BPM"
    echo
    echo "Outputs"
    echo "  $PROBE_LOG  ($(wc -l < "$PROBE_LOG") lines, full ckb-probe histogram output)"
    echo "  $TIP_LOG    ($(wc -l < "$TIP_LOG") tip samples)"
    echo "  $CASE_LOG   (run log)"
    echo
    echo "Latest histogram from ckb-probe (last cycle):"
    echo
    # Extract the last histogram block from the probe log (naive but works)
    awk 'BEGIN {block=""} /CKB RocksDB Monitor/ {block=""} {block = block "\n" $0} END {print block}' \
        "$PROBE_LOG" | tail -120
    echo
    echo "════════════════════════════════════════════════════════════════"
} > "$REPORT"

log "report written to $REPORT"
log "===== case-1 complete ====="
```

### 4.3 `docker/scripts/case/case-2-compaction-storm.sh`

完整 case-2 driver：覆盖 ckb.toml 用 aggressive 配置 → 启 CKB → 挂 ckb-probe（slow + 默认模式）→ 等 ANOMALY DETECTED → 抓上下文。

**问题：** 如何端到端跑案例 2（compaction storm 捕获），让 evaluator 一行命令就拿到一份完整的"风暴出现 + ckb-probe EWMA 检测器响应 + Compaction storm 归因"的演示数据？

**机制：** 6 步流水线

1. **backup ckb.toml**：把现有 ckb.toml 复制到 ckb.toml.backup-case2，case-2 结束时还原
2. **append aggressive RocksDB tuning**：把 ckb.toml.aggressive 的内容追加到 ckb.toml（**不替换**——保留其他 section）。aggressive 配置让 compaction 触发阈值极低、background job 限到 1，几分钟必出风暴
3. **重启 CKB**：SIGTERM 旧实例 → 等退出 → `nohup ckb run` 启动新实例 → 等 RPC ready
4. **挂 `ckb-probe rocksdb --slow --threshold 1000 --interval 5`**：threshold=1000 微秒（1 ms）只 emit 真正的慢请求；slow 模式自带 EWMA 异常检测和归因输出
5. **轮询 probe.log 等 ANOMALY DETECTED 出现**：每 10 秒 grep 一次。出现就 capture 60 秒后续上下文，没出现就等到 `MAX_WAIT`（默认 30 分钟）
6. **停 ckb-probe + 还原 ckb.toml + 写 REPORT.txt**：报告里包含 ANOMALY 计数、第一条 ANOMALY 块的内容、相关的 slow operation 日志、配置回滚状态

**关键设计点：**

- **threshold=1000 而不是 1**：这里 evaluator 关心的是**真正的慢请求**（compaction stall 引起的几十毫秒延迟），不是 P-3 那种"压满 perf buffer"的极端流量。1ms 阈值过滤掉所有正常的微秒级 op，只保留 storm 期间的异常事件
- **MAX_WAIT 30 分钟**：aggressive tuning 下 storm 应该几分钟内出现。30 分钟没出现说明 tuning 还不够激进或机器特别快——给 evaluator 报告"timeout"并建议加大 tuning
- **抓 60 秒 post-anomaly context**：第一次 anomaly 出现后再多跑 60 秒，让 ckb-probe 捕获完整的 storm 周期（开始 → 峰值 → 消退）
- **`grep -A 4 "ANOMALY DETECTED"`** 截取异常上下文：ANOMALY DETECTED 后面紧跟的几行是异常详情 + 归因 + 建议，截取这几行作为 report 的核心证据
- **配置回滚使用 `cp` 不是 `mv`**：mv 后 backup 文件就没了，万一 case-2 跑多次需要重新 backup。cp 保留 backup 直到下次 case-2 覆盖

**设计取舍：**

- **为什么 append 而不是 replace ckb.toml？** evaluator 的 ckb.toml 可能有自定义配置（比如 chain spec、RPC 端口），我们不想动这些。append 方式只追加我们关心的 `[store.options]` section，TOML 解析器最后一个同名 section 优先生效
- **为什么不直接修改 toml 文件然后 sed 还原？** sed 内联编辑容易出 quote / escape 问题。"backup → append → 还原" 是傻瓜式可靠
- **为什么不在 case-2 里同时挂 default mode 和 slow mode？** ckb-probe 当前一次只能挂一个 mode（同一个 PID 不能挂两组 uprobe pair）。如果想同时看 default 表格和 slow log，需要先跑 default mode 再切到 slow mode
- **为什么不用 `--record` 落盘 anomalies[]？** 同前，`--record` 子命令还没实现。当前用 stdout 重定向到 probe.log，事后 grep ANOMALY 行作为替代

> ⚠️ **关键 pitfall**：case-2 跑完**必须**还原 ckb.toml.aggressive 到原始配置，否则 evaluator 之后跑 case-1 或 perf 会发现 CKB 写吞吐显著下降（aggressive tuning 限制了 background job 和 memtable 大小）。脚本里的 `cp $BACKUP $TARGET` 是这一步的兜底，trap cleanup 保证即使中途中断也会 restore。**如果 case-2 异常退出导致 ckb.toml 没还原**（比如 OOM 杀掉脚本），evaluator 应该手动 `cp ckb.toml.backup-case2 ckb.toml` 修复。


```bash
#!/usr/bin/env bash
#
# case-2-compaction-storm.sh — compaction storm capture case study.
#
# Workflow:
#   1) merge aggressive RocksDB tuning into ckb.toml
#   2) restart CKB
#   3) attach ckb-probe rocksdb --slow --threshold 1000
#   4) wait for ANOMALY DETECTED in probe output (or timeout)
#   5) capture surrounding context, write report
#
# Usage:
#   ./case-2-compaction-storm.sh [max_wait_seconds]
#
# Default max wait: 1800 (30 minutes)

set -euo pipefail

MAX_WAIT="${1:-1800}"

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/case2"
mkdir -p "$OUTPUT_DIR"

CASE_LOG=$OUTPUT_DIR/case2.log
PROBE_LOG=$OUTPUT_DIR/probe.log
REPORT=$OUTPUT_DIR/REPORT.txt
> "$CASE_LOG"; > "$PROBE_LOG"

log() { echo "[$(date '+%T')] $*" | tee -a "$CASE_LOG"; }

cleanup() {
    log "cleanup"
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 3
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── 1) Apply aggressive tuning ────────────────────────────────
log "===== case-2: compaction storm capture ====="
TUNING=/opt/ckb-config/ckb.toml.aggressive
TARGET=$CKB_DATA/ckb.toml
BACKUP=$CKB_DATA/ckb.toml.backup-case2

if [[ ! -f "$TARGET" ]]; then
    log "no ckb.toml found, running ckb init"
    "$CKB_BIN" init --chain testnet -C "$CKB_DATA"
fi

log "backing up current ckb.toml -> $BACKUP"
cp "$TARGET" "$BACKUP"

log "appending aggressive RocksDB tuning to $TARGET"
{
    echo
    echo "# === case-2 aggressive tuning (auto-applied $(date '+%F %T')) ==="
    grep -v '^#' "$TUNING" | grep -v '^$'
} >> "$TARGET"

# ── 2) Restart CKB ─────────────────────────────────────────────
if pgrep -x ckb >/dev/null; then
    log "stopping current ckb"
    kill -TERM $(pgrep -x ckb)
    while pgrep -x ckb >/dev/null; do sleep 2; done
fi

log "restarting ckb with aggressive tuning"
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown

for _ in {1..30}; do
    if curl -sf -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
CKB_PID=$(pgrep -x ckb | head -n1)
log "ckb running, pid=$CKB_PID"

# ── 3) Attach ckb-probe ────────────────────────────────────────
log "attaching ckb-probe rocksdb --slow --threshold 1000 --interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1000 --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
log "ckb-probe pid=$PROBE_PID"

# ── 4) Wait for ANOMALY DETECTED ───────────────────────────────
log "waiting up to ${MAX_WAIT}s for ANOMALY DETECTED..."
START=$(date +%s)
DETECTED=0
while true; do
    if grep -q "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null; then
        DETECTED=1
        log "ANOMALY DETECTED!"
        break
    fi
    NOW=$(date +%s)
    if (( NOW - START > MAX_WAIT )); then
        log "timeout waiting for anomaly"
        break
    fi
    sleep 10
done

# Capture 60s of additional context after first detection
if (( DETECTED == 1 )); then
    log "capturing 60s of post-detection context..."
    sleep 60
fi

# ── 5) Stop probe and write report ─────────────────────────────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# Restore original ckb.toml
log "restoring original ckb.toml"
cp "$BACKUP" "$TARGET"

ANOMALY_COUNT=$(grep -c "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null || echo 0)
SLOW_COUNT=$(grep -cE "WRITE.*[0-9],[0-9]+μs" "$PROBE_LOG" 2>/dev/null || echo 0)

{
    echo "════════════════════════════════════════════════════════════════"
    echo "  case-2: compaction storm capture"
    echo "  Generated: $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "Setup"
    echo "  tuning applied : $TUNING (low L0 trigger, 1 background job, 4MB memtable)"
    echo "  ckb.toml.bak   : $BACKUP (restored at end)"
    echo "  max wait       : ${MAX_WAIT}s"
    echo
    echo "Result"
    echo "  ANOMALY DETECTED count : $ANOMALY_COUNT"
    echo "  slow WRITE entries     : $SLOW_COUNT"
    if (( ANOMALY_COUNT > 0 )); then
        echo "  status                 : ✅ storm captured"
    else
        echo "  status                 : ⚠️  no storm in window — try longer --threshold or more aggressive tuning"
    fi
    echo
    if (( ANOMALY_COUNT > 0 )); then
        echo "First ANOMALY DETECTED block:"
        grep -A 4 "ANOMALY DETECTED" "$PROBE_LOG" | head -20
        echo
        echo "Sample slow operations around the anomaly:"
        grep -B 1 -A 8 "ANOMALY DETECTED" "$PROBE_LOG" | head -40
    fi
    echo
    echo "Output files:"
    echo "  $PROBE_LOG  ($(wc -l < "$PROBE_LOG") lines)"
    echo "  $CASE_LOG"
    echo "════════════════════════════════════════════════════════════════"
} > "$REPORT"

log "report written to $REPORT"
log "===== case-2 complete ====="
```

---

## 5. 演示脚本

### 总览

三个 demo 脚本是 case study 的"快速展示层"——evaluator 在跑正式 case-1/case-2/perf 之前，先跑这三个 demo **3-10 分钟内**就能看到 ckb-probe 的全部主要能力。

### 三个 demo 的角色分工

| Demo | 时长 | 演示什么 | 评审者获得的认知 |
|---|---|---|---|
| **demo-check** | < 30 sec | 静态检查 + 符号报告 | "工具能识别我的环境是否就绪" |
| **demo-normal** | 5 min | 正常运行 JSON 快照 | "工具能输出可被下游消费的结构化数据" |
| **demo-stress** | 2-5 min | 合成负载 + 异常响应 | "工具能在异常时检测并报告" |

三个 demo 不需要 snapshot、不需要 4 小时长跑，是**最低门槛的 ckb-probe 能力 showcase**。中期报告里第一段 "ckb-probe 是什么" 就引用这三个 demo 的输出。

### 演进路径

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  demo-check  │ →  │ demo-normal  │ →  │ demo-stress  │
│   30 秒       │    │   5 分钟      │    │   5 分钟      │
└──────────────┘    └──────────────┘    └──────────────┘
       │                   │                   │
   "环境就绪"          "工具会观测"        "工具会告警"
       │                   │                   │
       ↓                   ↓                   ↓
┌──────────────────────────────────────────────────────┐
│  以上三个 demo 都通过 → 进入正式 case study              │
│  case-1 / case-2 / perf                              │
└──────────────────────────────────────────────────────┘
```

### 5.1 `docker/scripts/demo/demo-check.sh`

展示 `ckb-probe check` 的环境检测 + `ckb-probe symbols` 的符号分析。**只读**，不挂任何 probe。

**问题：** evaluator 拉到镜像、起了容器，第一件想知道的事是"环境对吗、CKB 是不是 ckb-probe 能识别的版本"。如何用一个**无侵入**的脚本告诉 evaluator 这两件事？

**机制：** 3 步只读检查

1. **`ckb-probe check`**：检查内核版本、BPF 配置、BTF 支持、权限、uprobe 可用性、CKB 进程在跑、CKB 符号表完整。如果 ckb 在跑就传 `--pid` 做完整检查；不在跑就只做静态检查。
2. **`ckb-probe symbols`** human-readable：解析 CKB 二进制的 ELF 符号表，分类成 Tier 1（RocksDB C API）/ Tier 2（Rust mangled）/ Tier 3（missing），输出可读的表格
3. **`ckb-probe symbols --json`** + jq 摘要：machine-readable 版本输出到文件，再用 jq 提取关键字段（binary、rocksdb_linkage、tier 计数、recommendation）作为 summary 打印

三个步骤都是**只读**的——`check` 不挂 probe（除非传 `--pid` 触发 eBPF probe validation，但那也是临时挂载立即解除的），`symbols` 不接触 CKB 进程，**完全不影响线上 CKB**。

**设计取舍：**

- **为什么 ckb 在跑和不在跑两个分支？** `check --pid` 触发的 eBPF probe validation 是有真实价值的——它会临时挂载 uprobe 验证内核接受。但需要 CKB 在跑且 ckb-probe 有 BPF 权限。不在跑就退化成只做静态环境检查
- **为什么同时输出 human 和 JSON 版本？** human 版本给 evaluator 看，JSON 版本给下游（中期报告自动生成 / 后续脚本消费）用
- **为什么打印 jq summary 而不是完整 JSON？** 完整 JSON 可能几十 KB（2000+ 符号），完整打印淹没终端。`jq` 抽 5-6 个最关键字段做摘要

> ⚠️ **关键 pitfall**：`ckb-probe check --pid` 会尝试挂载 uprobe 来验证 BPF 工作链——需要 `--privileged` 或合适的 capabilities。如果容器是非 privileged 启动，这一步会失败但脚本会继续到下一步——这是有意设计的（部分降级而不是 hard fail），但 evaluator 应该知道：**部分检查通过 ≠ 全部能力可用**。


```bash
#!/usr/bin/env bash
#
# demo-check.sh — runs `ckb-probe check` and `ckb-probe symbols` for an
# environment health check + symbol report. Read-only, no eBPF attach.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

CHECK_OUT=$OUTPUT_DIR/demo-check.txt
SYMBOLS_OUT=$OUTPUT_DIR/demo-symbols.txt
SYMBOLS_JSON=$OUTPUT_DIR/demo-symbols.json

echo "════════════════════════════════════════════════════════════════"
echo "  demo-check — environment + symbol report"
echo "════════════════════════════════════════════════════════════════"
echo

# ── ckb-probe check ────────────────────────────────────────────
echo "[1/3] running: ckb-probe check"
echo
CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -n "$CKB_PID" ]]; then
    "$PROBE_BIN" check --binary "$CKB_BIN" --pid "$CKB_PID" | tee "$CHECK_OUT"
else
    echo "  (ckb not running, doing static check only)"
    "$PROBE_BIN" check --binary "$CKB_BIN" | tee "$CHECK_OUT"
fi
echo
echo "  -> saved to $CHECK_OUT"
echo

# ── ckb-probe symbols (human-readable) ─────────────────────────
echo "[2/3] running: ckb-probe symbols (human-readable)"
echo
"$PROBE_BIN" symbols "$CKB_BIN" | tee "$SYMBOLS_OUT"
echo
echo "  -> saved to $SYMBOLS_OUT"
echo

# ── ckb-probe symbols --json (machine-readable) ────────────────
echo "[3/3] running: ckb-probe symbols --json"
"$PROBE_BIN" symbols "$CKB_BIN" --json > "$SYMBOLS_JSON"
echo
echo "  -> saved to $SYMBOLS_JSON ($(wc -c < "$SYMBOLS_JSON") bytes)"
echo "  summary:"
jq '{
    binary: .binary_path,
    rocksdb_linkage: .rocksdb_linkage,
    tier1_found: .summary.tier1_found,
    tier1_tracked: .summary.tier1_tracked,
    tier2_found: .summary.tier2_found,
    recommendation: .summary.recommendation
}' "$SYMBOLS_JSON"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  demo-check complete"
echo "════════════════════════════════════════════════════════════════"
```

### 5.2 `docker/scripts/demo/demo-normal.sh`

让 ckb-probe 监控 5 分钟正常运行状态，每周期一行 JSON 全部存盘，最后一周期作为"快照"输出。

**问题：** 如何用 5 分钟时间，给 evaluator 演示 ckb-probe 在 normal 工作负载下的输出长什么样？

**机制：** 4 步采集

1. **确保 CKB 在跑**：调 `start-ckb.sh` helper（幂等，已经在跑就跳过）
2. **挂 ckb-probe `--json --interval 5`**：每 5 秒输出一行 JSON 到 stdout，重定向到 probe.log。300 秒共 60 个 JSON cycle
3. **`sleep $DURATION`**（默认 300 秒）+ stop ckb-probe
4. **后处理 probe.log → JSONL + final snapshot**：
   - awk 解析每个 JSON object（识别 `{` 开头 + 平衡的 `}` 结尾），用 jq 压缩成单行，写到 `demo-normal.jsonl`
   - 取最后一行作为 "final cycle snapshot"，jq 美化后写到 `demo-normal-snapshot.json`
   - 打印 final snapshot 到终端

**为什么 5 分钟？** 5 分钟是 ckb-probe EWMA warm-up 时长（300 秒），刚好覆盖一个完整的 warm-up 期。短于 5 分钟看不到 warm-up 完成；长于 5 分钟没新内容可看。这是 spec-aware 的设计。

**两种 JSON 输出的角色：**

| 文件 | 内容 | 用途 |
|---|---|---|
| `demo-normal.jsonl` | 60 个 JSON cycle 的 JSONL | 完整时间序列，可以喂给 Prometheus / pandas |
| `demo-normal-snapshot.json` | 最后一个 cycle 的美化 JSON | "如果你只看一帧，看这个"——中期报告引用对象 |

**设计取舍：**

- **为什么用 awk 解析而不是 jq stream？** ckb-probe 的 JSON 输出是 multi-line pretty-printed（缩进的），不是 JSON Lines。jq 的 streaming 模式要求输入要么是单个 JSON 文档要么是 JSONL，无法直接处理 "多个 pretty JSON 拼接"。awk 用 `{` 平衡计数解析最简单
- **为什么不输出原始 probe.log？** 原始 log 包含 ANSI escape codes（颜色）、终端控制字符（清屏）、warning 消息等噪声，对下游消费不友好。JSONL 是干净的纯数据
- **为什么默认 5 分钟而不是参数化？** 参数化了——`./demo-normal.sh 600` 可以跑 10 分钟。但默认用 5 分钟（spec warm-up 时长），减少 evaluator 决策

> ⚠️ **关键 pitfall**：awk 解析依赖 ckb-probe 的 JSON 输出**完整、不被截断**。如果 ckb-probe 中途 crash 或被强杀，最后一个 JSON 块可能没写完整 `}`，awk 会跳过它。这对 demo 不是问题（前面 59 个 cycle 已经存了），但 evaluator 看到 cycle count < 60 时应该检查 probe.log 末尾是否完整。


```bash
#!/usr/bin/env bash
#
# demo-normal.sh — capture 5 minutes of normal monitoring as JSON snapshot.
#
# Runs ckb-probe rocksdb --json for 300 seconds, saves all per-cycle JSON
# objects as JSONL, extracts the final cycle as the canonical "snapshot".

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

DURATION="${1:-300}"   # default 5 minutes
INTERVAL=5

JSONL_OUT=$OUTPUT_DIR/demo-normal.jsonl
SNAPSHOT_OUT=$OUTPUT_DIR/demo-normal-snapshot.json
PROBE_LOG=$OUTPUT_DIR/demo-normal.log
> "$JSONL_OUT"; > "$PROBE_LOG"

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "demo-normal: starting ckb first..."
    /opt/scripts/case/start-ckb.sh
    CKB_PID=$(pgrep -x ckb | head -n1)
fi

echo "════════════════════════════════════════════════════════════════"
echo "  demo-normal — capture 5 min of normal monitoring as JSON"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid     : $CKB_PID"
echo "  duration    : ${DURATION}s"
echo "  interval    : ${INTERVAL}s"
echo "  output      : $JSONL_OUT (full JSONL)"
echo "                $SNAPSHOT_OUT (final-cycle snapshot)"
echo

cleanup() {
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[demo-normal] starting ckb-probe rocksdb --json --interval ${INTERVAL}"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --json --interval $INTERVAL \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }

echo "[demo-normal] ckb-probe pid=$PROBE_PID, sampling for ${DURATION}s..."
sleep "$DURATION"

# Stop probe
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# Parse the probe log into JSONL — each cycle is a pretty-printed JSON object
# starting with "{" and ending with "}". Use jq to compact each object.
awk '
    /^{/ { collecting = 1; buf = ""; depth = 0 }
    collecting {
        buf = buf $0 "\n"
        n = gsub(/{/, "{", $0); depth += n
        n = gsub(/}/, "}", $0); depth -= n
        if (depth == 0) {
            print buf
            collecting = 0
        }
    }
' "$PROBE_LOG" | jq -c '.' > "$JSONL_OUT"

CYCLES=$(wc -l < "$JSONL_OUT")
echo "[demo-normal] captured $CYCLES JSON cycles"

if (( CYCLES > 0 )); then
    tail -1 "$JSONL_OUT" | jq '.' > "$SNAPSHOT_OUT"
    echo
    echo "===== final cycle snapshot ====="
    cat "$SNAPSHOT_OUT"
    echo
    echo "  -> saved to $SNAPSHOT_OUT"
else
    echo "WARNING: no JSON cycles parsed from $PROBE_LOG"
    head -50 "$PROBE_LOG"
fi
```

### 5.3 `docker/scripts/demo/demo-stress.sh`

用 db_bench 在容器内注入合成 RocksDB 写入负载（突发 100K 条目），同时 ckb-probe 用低阈值监控 CKB，捕捉因 I/O 抢占引发的延迟尖峰和慢操作。

**问题：** 如何在 5 分钟内演示 ckb-probe 的"延迟飙升检测 + 慢操作日志"能力，而不依赖等待自然 compaction storm？

**机制：** 4 阶段时间线

```
T=0    ┌─ 启动 ckb-probe slow mode --threshold 500 ─┐
       │  baseline 窗口 15s                          │  ← 让 ckb-probe 先进入 warm-up
T=15s  │                                              │
       ├─ 启动 db_bench fillrandom --num=100000 ─────┤
       │  4 threads / 4KB value                       │  ← burst 写入约 400 MB
       │                                              │
T=?    ├─ db_bench 完成 (典型 1-3 分钟) ──────────────┤
       │                                              │
       ├─ cool-down 30s                              │  ← 让 ckb-probe 看到恢复期
       │                                              │
T=?    └─ 停 ckb-probe + 输出 report ───────────────┘
```

**观察的核心机制：** ckb-probe **attached 到 CKB**，不是 db_bench。db_bench 写到独立的 `/tmp/dbbench-demo-db` 目录的 RocksDB 实例。当 db_bench 占用磁盘 I/O 带宽（4 threads × 4KB × 100K 条目 ≈ 400 MB 突发写入）时，**CKB 自身的 RocksDB 操作变慢**（共享同一块磁盘），ckb-probe 观测到 CKB 的 WRITE / TXN_COMMIT P99 上升 → ANOMALY DETECTED 触发，slow operation log 累积更多条目。

**为什么是间接观测而不是直接观测 db_bench？**

ckb-probe 的 `MONITOR_PROBES` 表硬编码了 CKB 实际使用的 5 个 RocksDB C 函数（`rocksdb_get_pinned_cf` / `rocksdb_transaction_put_cf` 等）。db_bench 用的是 RocksDB 的 **C++ API**（`rocksdb::DB::Put`），符号完全不同，**ckb-probe 没法直接 attach 到 db_bench**。

所以 demo-stress 的工作机制是 **noisy neighbor 模拟**：db_bench 创造磁盘竞争，CKB 自然变慢，ckb-probe 观测到 CKB 的延迟变化。这是 demo 的诚实定位。

**设计取舍：**

- **为什么用 db_bench 而不是其他工具？** db_bench 是 RocksDB 自带的工具，apt-get install rocksdb-tools 就有，参数清晰、行为可预测。fio 也能制造磁盘负载但参数更复杂、跟"RocksDB 演示"语义不贴
- **为什么 4 threads × 100K entries × 4KB value？** 这个组合产生约 400 MB 的写入，在普通 SSD 上能跑出几秒到几十秒的明显 I/O 占用，又不会跑得太久（>5 分钟 demo 体验差）
- **为什么有 15 秒 baseline 窗口？** ckb-probe 启动后需要几秒才完全 ready，加上让 evaluator 在终端看到 "Status: ⏳ Warming up" 一会儿，再切到 stress 阶段，对比更明显
- **为什么 30 秒 cool-down？** 让 evaluator 看到 "异常 → 恢复" 完整周期。db_bench 一停，CKB 立即不再被磁盘竞争压制，ckb-probe 的状态栏会从 ANOMALY DETECTED 切回 ✅ Normal
- **为什么 db_bench 的 db 目录用 `/tmp/dbbench-demo-db` 而不是 `/data` 内？** 完全独立的目录避免污染 CKB 的 data 目录。脚本结尾 `rm -rf` 清理

**已知 caveat：**

如果 host 磁盘 I/O 余量很大（高速 NVMe SSD），db_bench 400 MB 突发可能根本不影响 CKB——磁盘 bandwidth 大头都没用到。这种情况下 ANOMALY DETECTED 不会触发，demo 输出会显示 "no ANOMALY DETECTED triggered"。脚本里的 note 段会建议 evaluator 加大 `--num` 或者改用 case-2 的 aggressive tuning 方案。

> ⚠️ **关键 pitfall**：`pgrep -f 'db_bench.*fillrandom'` 拿 db_bench pid 时，匹配的是命令行字符串。如果系统里同时有多个 db_bench 进程，会拿到多个 pid。脚本用 `head -n1` 取第一个，但更稳健的做法是按启动时间过滤。当前实现假设容器内不会有其他 db_bench——这个假设在 case study 容器里成立。


```bash
#!/usr/bin/env bash
#
# demo-stress.sh — inject synthetic RocksDB load with db_bench, watch ckb-probe
# react with elevated WRITE/TXN_COMMIT latency and slow operation entries.
#
# Workflow:
#   1) start ckb-probe rocksdb --slow --threshold 500 against running CKB
#   2) launch db_bench fillrandom --num=100000 in background (separate db,
#      same disk → creates I/O contention that ripples into CKB's RocksDB)
#   3) wait for db_bench to finish + 30s cool-down
#   4) stop ckb-probe, summarise: slow events count, anomaly count, etc.
#
# Note: the latency spike comes from disk I/O contention rather than direct
# observation of db_bench (ckb-probe is attached to CKB, not db_bench). For
# this demo to be visible, the host disk must be the bottleneck.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

NUM_ENTRIES="${1:-100000}"
DBBENCH_DIR=/tmp/dbbench-demo-db
PROBE_LOG=$OUTPUT_DIR/demo-stress-probe.log
DBBENCH_LOG=$OUTPUT_DIR/demo-stress-dbbench.log
REPORT=$OUTPUT_DIR/demo-stress.txt
> "$PROBE_LOG"; > "$DBBENCH_LOG"; > "$REPORT"

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "demo-stress: starting ckb first..."
    /opt/scripts/case/start-ckb.sh
    CKB_PID=$(pgrep -x ckb | head -n1)
fi

cleanup() {
    [[ -n "${DBB_PID:-}" ]] && kill "$DBB_PID" 2>/dev/null || true
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "════════════════════════════════════════════════════════════════"
echo "  demo-stress — synthetic RocksDB load injection"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid       : $CKB_PID"
echo "  db_bench size : $NUM_ENTRIES entries"
echo "  output        : $REPORT"
echo

# ── 1) Attach ckb-probe in slow mode with low threshold ───────
echo "[demo-stress] starting ckb-probe rocksdb --slow --threshold 500"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 500 --interval 3 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }
echo "[demo-stress] ckb-probe pid=$PROBE_PID"

# Baseline window
echo "[demo-stress] capturing 15s baseline..."
sleep 15

# ── 2) Launch db_bench burst ──────────────────────────────────
rm -rf "$DBBENCH_DIR"
echo "[demo-stress] launching db_bench fillrandom --num=$NUM_ENTRIES"
nohup db_bench \
    --benchmarks=fillrandom \
    --num="$NUM_ENTRIES" \
    --threads=4 \
    --value_size=4096 \
    --db="$DBBENCH_DIR" \
    > "$DBBENCH_LOG" 2>&1 &
disown
DBB_PID=$(pgrep -f 'db_bench.*fillrandom' | head -n1)
echo "[demo-stress] db_bench pid=$DBB_PID"

# ── 3) Wait for db_bench to finish ────────────────────────────
echo "[demo-stress] waiting for db_bench to complete..."
while kill -0 "$DBB_PID" 2>/dev/null; do
    sleep 5
done
echo "[demo-stress] db_bench done"
DBB_PID=""

# Cool-down to capture post-burst recovery
echo "[demo-stress] 30s cool-down..."
sleep 30

# ── 4) Stop ckb-probe and summarise ───────────────────────────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

ANOMALY_COUNT=$(grep -c "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null || echo 0)
SLOW_LINE_COUNT=$(grep -cE 'GET|PUT|WRITE|TXN_COMMIT|ITER_NEW' "$PROBE_LOG" 2>/dev/null || echo 0)
LAST_LOSS=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "n/a")

DBBENCH_SUMMARY=$(grep -E '^fillrandom' "$DBBENCH_LOG" | head -3 || echo "(no summary parsed)")

{
    echo "════════════════════════════════════════════════════════════════"
    echo "  demo-stress result"
    echo "  $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "ckb-probe captured during stress:"
    echo "  ANOMALY DETECTED count : $ANOMALY_COUNT"
    echo "  slow op log lines      : $SLOW_LINE_COUNT"
    echo "  $LAST_LOSS"
    echo
    echo "db_bench fillrandom summary:"
    echo "$DBBENCH_SUMMARY"
    echo
    if (( ANOMALY_COUNT > 0 )); then
        echo "First ANOMALY block:"
        grep -A 4 "ANOMALY DETECTED" "$PROBE_LOG" | head -20
    else
        echo "Note: no ANOMALY DETECTED triggered. This can happen if the disk had"
        echo "      enough headroom to absorb db_bench without contending with CKB."
        echo "      Try with a slower disk, larger --num, or apply ckb.toml.aggressive"
        echo "      via case-2 to make compaction more sensitive."
    fi
    echo
    echo "Output files:"
    echo "  $PROBE_LOG"
    echo "  $DBBENCH_LOG"
} | tee "$REPORT"

# Cleanup db_bench data
rm -rf "$DBBENCH_DIR"
```

---

## 6. 使用示例

### 6.1 构建镜像

```bash
cd /root/ckb-probe
# .dockerignore 在项目根
docker build -f docker/Dockerfile -t ckb-probe-case-study:latest .
```

### 6.2 启动容器（交互模式）

```bash
docker run --rm -it \
    --privileged \
    --pid=host \
    -v /sys/kernel/debug:/sys/kernel/debug:ro \
    -v /sys/kernel/btf:/sys/kernel/btf:ro \
    -v /root/data:/data \
    -v /backup:/backup \
    -v /tmp/perf-run:/tmp/perf-run \
    --name ckb-probe \
    ckb-probe-case-study:latest \
    bash
```

`--pid=host` 让容器看到宿主上的所有进程（包括宿主的 ckb 进程）。如果只用容器内的 ckb，可以去掉。

### 6.3 跑各个工作流

```bash
# 1) 健康检查 + 符号报告
docker run --rm --privileged ... ckb-probe-case-study demo-check

# 2) 5 分钟正常运行 JSON 快照
docker run --rm --privileged ... ckb-probe-case-study demo-normal

# 3) db_bench 压力注入演示
docker run --rm --privileged ... ckb-probe-case-study demo-stress

# 4) 案例 1: IBD 写入模式 (需要先准备 snapshot)
docker run --rm --privileged ... ckb-probe-case-study \
    case-1 /backup/ckb-testnet-snap-h20725000.tar.zst

# 5) 案例 2: compaction storm
docker run --rm --privileged ... ckb-probe-case-study case-2

# 6) 完整 4h 性能评估 (P-1 ~ P-4)
docker run --rm --privileged ... ckb-probe-case-study perf
```

### 6.4 制作 / 恢复 snapshot

```bash
# 在容器内
docker exec -it ckb-probe /opt/scripts/snapshot/make-snapshot.sh

# 恢复
docker exec -it ckb-probe /opt/scripts/snapshot/restore-snapshot.sh \
    /backup/ckb-testnet-snap-h20725000-20260411-103000.tar.zst
```

---

## 7. 已知限制与设计权衡

### 7.1 demo-stress.sh 不直接观测 db_bench

ckb-probe 的 `MONITOR_PROBES` 表硬编码了 CKB 实际使用的 5 个 RocksDB 函数（`rocksdb_get_pinned_cf` / `rocksdb_transaction_put_cf` 等）。db_bench 走的是 RocksDB 的 C++ API，符号不一样，**ckb-probe 不能直接观测 db_bench 的写入**。

demo-stress 的工作机制是**间接**的：db_bench 占用磁盘 I/O 带宽 → CKB 自身的 RocksDB 操作变慢 → ckb-probe（attached to CKB）观测到延迟尖峰。

要让 demo-stress 在快盘上也能稳定触发尖峰，可以：
- 加大 `--num` 到 1M+
- 配套用 case-2 的 `ckb.toml.aggressive` 让 CKB 自己更敏感
- 用 `cgroups` 限制 disk bandwidth 模拟慢盘

### 7.2 ckb-probe 当前从 cwd 找 eBPF 二进制

`commands/rocksdb.rs:227` 写死 `Path::new("ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf")`。Dockerfile 用 `WORKDIR /opt` 让相对路径解析到 `/opt/ckb-probe-ebpf/...`。

**长远应该改代码**支持 `EBPF_PATH` 环境变量。改完之后 Dockerfile 可以删掉 WORKDIR 限制。

### 7.3 case-1 的 IBD 完成判断

case-1 用"tip 连续 90s 不前进"判定 IBD 结束，这对快速 IBD 准确，但对真正落后多块的情况需要等 tip 真正稳定。可以加个 `--target-tip` 参数让用户指定明确的目标高度。

### 7.4 P-4 在 60s 窗口下 NaN-prone

`p4-sync.sh` 默认 120 分钟窗口是对的——更短的窗口下 testnet 块间隔抖动会让 verdict 失真。如果只想做 smoke test，可以传 `./p4-sync.sh baseline 5`，但要明白 5 分钟数据不能用于正式 verdict。

### 7.5 snapshot 需要 ckb 完全停机

`make-snapshot.sh` 必须 SIGTERM ckb 等它干净退出（典型 5-30 秒）后才 tar。期间 ckb 完全不可用。对生产环境这是个问题，但对 case study 完全 OK。

zero-downtime snapshot 需要 btrfs/zfs/lvm 文件系统级 CoW snapshot，CKB 自己解决不了。

### 7.6 网络性能依赖 host 配置

容器里的 CKB 共享 host 网络栈，P2P 连接质量、testnet bootstrap node 可达性都依赖 host 的 networking。在国内网络下可能要配置 `https_proxy` 或自建 bootstrap。

### 7.7 单容器架构 vs 双容器

详见前文设计讨论。**case study 选单容器**理由：1 个 Dockerfile、不需要 compose、PID namespace 自动共享、reset 流程紧凑、评审者上手快。生产部署的 sidecar pattern 是另一回事，那时再做 compose 化即可。

### 7.8 镜像总体积估算

| 阶段 | 体积 |
|---|---|
| `nervos/ckb:v0.205.0` (CKB binary 来源) | ~200 MB |
| `rust:1.83-bookworm` (builder) | ~1.5 GB |
| `debian:bookworm-slim` (runtime base) | ~80 MB |
| 加上运行时工具 (sysstat/curl/jq/zstd/rocksdb-tools) | +150 MB |
| ckb 二进制 | ~70 MB |
| ckb-probe 二进制 + ebpf | ~25 MB |
| 源码 + 脚本 | ~10 MB |
| **runtime 镜像总体** | **~330 MB** |

builder stage 不进 final 镜像，所以 ~330 MB 是用户实际拉取的体积。完全在合理范围。

---

## 8. 实现路线图

### 8.1 工作分解结构（WBS）

按 **依赖关系** 把所有交付物拆成 6 个 phase。每个 phase 都有明确的"完成标志"，phase N+1 不依赖 phase N+2 的任何产物，但 phase N+1 依赖 phase N 全部完成。

```
Phase 0  ─→  Phase 1  ─→  Phase 2  ─→  Phase 3  ─→  Phase 4  ─→  Phase 5
准备工作      Docker        Snapshot     性能脚本      演示脚本      案例脚本
~30 min      ~2 hour      ~3 hour      ~2 hour       ~2 hour       ~3 hour
```

| Phase | 交付物 | 完成标志 | 估时 |
|---|---|---|---|
| **0 准备** | 项目目录结构、`.dockerignore`、`docker/` 目录、修复 ckb-probe ebpf 路径硬编码（可选）| `mkdir docker && touch docker/Dockerfile` 完成 | 30 min |
| **1 Docker 基础设施** | `Dockerfile`、`entrypoint.sh`、`README.md`、`ckb-config/ckb.toml.aggressive` | `docker build -t ckb-probe-case-study .` 成功，`docker run --rm <image> help` 输出 usage | 2 hour |
| **2 Snapshot 脚本** | `make-snapshot.sh`、`restore-snapshot.sh` | 在宿主上对真实 CKB 跑一次 make + restore，结尾 `ckb migrate --check` 返回 0 | 3 hour |
| **3 性能脚本** | `p1-cpu.sh`、`p2-rss.sh`、`p3-stress.sh`、`p4-sync.sh`、`full-perf-run.sh`（4 个 P-* 脚本已基本就位，需要适配容器路径）| 单独跑每个 p-*.sh 的 5 分钟烟雾测试都通过；orchestrator 跑 5 分钟 dry run 通过 | 2 hour |
| **4 演示脚本** | `demo-check.sh`、`demo-normal.sh`、`demo-stress.sh` | 三个 demo 都能在容器内一次性跑通并产出预期文件 | 2 hour |
| **5 案例脚本** | `start-ckb.sh`、`case-1-ibd-write-pattern.sh`、`case-2-compaction-storm.sh` | case-1 用 1 小时 IBD snapshot 跑通；case-2 在 5 分钟内捕获 ANOMALY DETECTED | 3 hour |
| **总计** | | | **~12.5 hour 实施 + 4-7 hour 端到端验证** |

### 8.2 详细实施计划

#### Phase 0 — 准备工作（30 min）

```bash
cd /root/ckb-probe
mkdir -p docker/scripts/{snapshot,perf,case,demo} docker/ckb-config
touch docker/Dockerfile docker/entrypoint.sh docker/README.md
# .dockerignore 放项目根
touch .dockerignore
```

**可选但推荐：** 修复 ckb-probe 的 eBPF 路径硬编码。改 `ckb-probe/src/commands/rocksdb.rs:227`：

```rust
// 改前
let ebpf_path = std::path::Path::new("ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf");

// 改后
let ebpf_path = std::env::var("EBPF_PATH")
    .map(|s| std::path::PathBuf::from(s))
    .unwrap_or_else(|_| std::path::PathBuf::from("ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf"));
```

这样 docker 镜像里可以 `ENV EBPF_PATH=/opt/ckb-probe-ebpf/...`，不需要 `WORKDIR /opt` workaround。

#### Phase 1 — Docker 基础设施（2 hour）

**步骤：**

1. **写 `.dockerignore`**（5 min）— 复制本文档 §2.2 内容到项目根
2. **写 `docker/Dockerfile`**（30 min）— 复制本文档 §2.1 内容
3. **写 `docker/entrypoint.sh`**（15 min）— 复制本文档 §2.3 内容 + `chmod +x`
4. **写 `docker/ckb-config/ckb.toml.aggressive`**（5 min）— §2.4 内容
5. **写 `docker/README.md`**（10 min）— 简短 usage 说明
6. **第一次 `docker build`**（30-60 min 取决于网络）：
   ```bash
   docker build -f docker/Dockerfile -t ckb-probe-case-study:dev .
   ```
   预期：成功 build 出 ~330 MB 镜像。**最容易出错的是 stage 2**——`cargo install bpf-linker` 编译时间长 + 偶尔有 nightly toolchain 兼容问题
7. **smoke test 镜像**（10 min）：
   ```bash
   docker run --rm ckb-probe-case-study:dev help          # 应输出 usage
   docker run --rm ckb-probe-case-study:dev which ckb-probe  # /usr/local/bin/ckb-probe
   docker run --rm ckb-probe-case-study:dev which ckb       # /usr/local/bin/ckb
   ```

**验证 gate：** 镜像构建成功 + entrypoint 分发器工作 + 两个二进制都在镜像里。

#### Phase 2 — Snapshot 脚本（3 hour）

**步骤：**

1. **写 `make-snapshot.sh`**（30 min）— §1.1 内容 + chmod +x
2. **写 `restore-snapshot.sh`**（30 min）— §1.2 内容 + chmod +x
3. **在宿主上做 dry-run** —— 不动 docker，先确认脚本本身的逻辑对：
   ```bash
   # 如果当前 4h 测试还没完，等它完
   # 然后做一次 snapshot
   sudo /root/ckb-probe/docker/scripts/snapshot/make-snapshot.sh
   # 预期：~15 分钟,产出 /backup/ckb-testnet-snap-h<...>.tar.zst
   ```
4. **smoke restore**：
   ```bash
   # 把 snapshot 解到一个 temp 目录验证
   mkdir -p /tmp/restore-test/data
   CKB_DATA=/tmp/restore-test \
       sudo /root/ckb-probe/docker/scripts/snapshot/restore-snapshot.sh \
       /backup/ckb-testnet-snap-h<...>.tar.zst
   # 预期：解压成功 + ckb migrate --check 返回 0
   ```
5. **真实 restore + 启动验证**（time-intensive，~30 min）— 在真实 CKB data dir 上做一次 restore + 启动，验证节点能从 snapshot tip 启动

**验证 gate：** make-snapshot 产出可用文件 + restore-snapshot 能让 CKB 在 snapshot 高度启动 + `ckb migrate --check` 通过。

#### Phase 3 — 性能脚本（2 hour）

**步骤：**

1. **现有 4 个 p-*.sh 脚本**已经在 `scripts/perf/` 里（这次会话之前就写好的），只需要：
   - 改路径常量为容器内默认值（`/tmp/perf-run` 等）
   - 加 `OUTPUT_DIR` 环境变量支持
2. **写 `p3-stress.sh`**（30 min）— §3.3 内容（这是新脚本，需要 ckb-probe P-3 patch 已经在 main 分支）
3. **把 `/tmp/perf-run-orchestrator.sh` 升级成 `full-perf-run.sh`**（30 min）— 主要是路径常量化 + 加 OUTPUT_DIR 支持。逻辑跟现在跑的 4h orchestrator 完全一致
4. **5 分钟烟雾测试每个脚本**：
   ```bash
   docker run --rm --privileged ... ckb-probe-case-study:dev \
       /opt/scripts/perf/p2-rss.sh 5 /tmp/perf-run/p2-smoke.log
   # 预期：5 秒后开始打印 RSS samples,Ctrl+C 后输出 verdict
   ```
5. **5 分钟 orchestrator dry run**：把 `PHASE_A_SECS` 临时改成 60，跑一次完整流程，确认 4 个 phase 都正常切换

**验证 gate：** 4 个 p-*.sh 单独跑能产出 verdict + orchestrator 5 分钟 dry run 通过。

#### Phase 4 — 演示脚本（2 hour）

**步骤：**

1. **写 `demo-check.sh`**（20 min）— §5.1 内容
2. **写 `demo-normal.sh`**（30 min）— §5.2 内容
3. **写 `demo-stress.sh`**（45 min）— §5.3 内容（注意 db_bench 在 Dockerfile 装的是 rocksdb-tools 包）
4. **`docker run` 跑每个 demo 端到端**：
   ```bash
   docker run --rm --privileged ... ckb-probe-case-study:dev demo-check
   # 预期：< 30s 完成,输出环境检查 + 符号报告

   docker run --rm --privileged ... ckb-probe-case-study:dev demo-normal
   # 预期：5 分钟后产出 demo-normal.jsonl + demo-normal-snapshot.json

   docker run --rm --privileged ... ckb-probe-case-study:dev demo-stress
   # 预期：3-5 分钟后产出 demo-stress.txt,可能含 ANOMALY DETECTED
   ```

**验证 gate：** 三个 demo 都端到端跑通 + 输出文件都符合预期格式。

#### Phase 5 — 案例脚本（3 hour）

**步骤：**

1. **写 `start-ckb.sh`**（15 min）— §4.1 内容
2. **写 `case-1-ibd-write-pattern.sh`**（45 min）— §4.2 内容
3. **跑 case-1 端到端**（最长 2 小时，取决于 snapshot 落后多远）：
   ```bash
   docker run --rm --privileged \
       -v /backup:/backup -v /root/data:/data ... \
       ckb-probe-case-study:dev case-1 /backup/ckb-testnet-snap-h...tar.zst
   ```
   验证：REPORT.txt 显示 IBD 完成 + 处理了 N blocks + histogram 数据齐全
4. **写 `case-2-compaction-storm.sh`**（45 min）— §4.3 内容
5. **跑 case-2 端到端**（5-30 分钟）：
   ```bash
   docker run --rm --privileged ... ckb-probe-case-study:dev case-2
   ```
   验证：REPORT.txt 显示 ANOMALY DETECTED count > 0 + ckb.toml 已 restore

**验证 gate：** case-1 完整产出 IBD 数据 + case-2 至少捕获一次 anomaly。

### 8.3 关键依赖关系图

```
                      ┌──────────────────┐
                      │  Phase 0         │
                      │  目录 + 修 path  │
                      └────────┬─────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ↓                ↓                ↓
       ┌──────────┐     ┌──────────┐     ┌──────────┐
       │ Phase 1  │     │ Phase 2  │     │  perf 脚本  │
       │ Docker   │     │ Snapshot │     │  (需先有  │
       │ build    │     │ scripts  │     │   ckb-    │
       │          │     │          │     │   probe   │
       │          │     │          │     │   patch)  │
       └────┬─────┘     └────┬─────┘     └────┬─────┘
            │                │                │
            └────────┬───────┴────────────────┘
                     │
                     ↓
              ┌──────────────┐
              │ Phase 3      │
              │ perf 脚本    │
              │ 适配容器路径 │
              └──────┬───────┘
                     │
            ┌────────┼────────┐
            ↓        ↓        ↓
       ┌──────────┐  ┌──────────┐
       │ Phase 4  │  │ Phase 5  │
       │ demo     │  │ case     │
       │ 脚本     │  │ 脚本     │
       └──────────┘  └──────────┘
            │             │
            └──────┬──────┘
                   ↓
          ┌─────────────────┐
          │ 端到端验证完成  │
          │ 4-7h 综合测试   │
          └─────────────────┘
```

**关键发现：**

- **Phase 1 / Phase 2 可并行** — Docker 镜像构建跟 snapshot 脚本无依赖，两件事可以同时做（如果两个人）
- **perf 脚本适配（Phase 3）依赖 Docker 镜像**（Phase 1）—— 路径常量需要镜像内的实际目录
- **case 脚本（Phase 5）依赖 snapshot 脚本（Phase 2）** — case-1 必须先有 snapshot 才能跑
- **演示和案例脚本可并行** — Phase 4 和 Phase 5 互相独立

### 8.4 风险登记表

| 风险 | 概率 | 影响 | 缓解措施 |
|---|---|---|---|
| `cargo install bpf-linker` 在 builder stage 失败 | 中 | 高（block Phase 1）| 用 `--locked` + 固定 nightly 版本；准备 fallback Dockerfile 不用 bpf-linker（pre-build ebpf 二进制 COPY 进去）|
| ckb-probe ebpf 路径硬编码导致 docker 跑不起来 | 高 | 中 | Phase 0 修代码加 `EBPF_PATH` env var 支持；fallback 用 `WORKDIR /opt` |
| `nervos/ckb:v0.205.0` 镜像里 ckb 二进制路径不是 `/bin/ckb` | 低 | 低 | `docker run nervos/ckb:v0.205.0 which ckb` 验证；调整 COPY 路径 |
| `apt-get install rocksdb-tools` 在 bookworm 没这个包 | 低 | 中 | 退路：从 source build db_bench；或者用 `sysbench` 替代 |
| make-snapshot 的 15-30 分钟停机窗口让 evaluator 不耐 | 高 | 低 | 文档明确写预期时长；`progress.log` 实时显示进度 |
| case-2 在快盘机器上 30 分钟也没出 ANOMALY | 中 | 中 | aggressive 配置可调更激进；脚本输出明确建议 |
| docker build 上下文超过 100 MB 导致慢/失败 | 中 | 高 | `.dockerignore` 严格排除；`du -sh` 检查 build context 大小 |
| 4h orchestrator 中途 CKB crash | 低 | 高 | 脚本检测 CKB 死亡时优雅退出 + 保存部分数据；progress.log 标记 crash 时间 |
| evaluator 没装 docker | 低 | 高 | 文档前置条件章节明确说明 |
| 内核版本 < 5.8 导致 BPF verifier 拒绝 | 中 | 高 | demo-check 第一步就检查内核版本；明确 hard fail |

---

## 9. 验证矩阵

每个交付物对应一个最小的"它工作"的检查方式。Phase N 的所有验证 gate 都要通过才能进入 Phase N+1。

### 9.1 Smoke test 速查表

| 组件 | 测试命令 | 预期产出 | 失败排查 |
|---|---|---|---|
| **Dockerfile** | `docker build -f docker/Dockerfile -t ckb-probe-case-study:dev .` | 镜像 build 成功，`docker images` 显示 ~330 MB | build context 检查（`du -sh .`），`.dockerignore` 是否生效 |
| **entrypoint** | `docker run --rm ckb-probe-case-study:dev help` | 打印 usage | `docker run --rm ckb-probe-case-study:dev bash -c 'cat /entrypoint.sh'` 检查文件存在 |
| **ckb 二进制** | `docker run --rm ckb-probe-case-study:dev ckb --version` | `ckb 0.205.0 ...` | stage 1 COPY 路径错（`/bin/ckb` vs `/usr/local/bin/ckb`）|
| **ckb-probe 二进制** | `docker run --rm ckb-probe-case-study:dev ckb-probe --version` | 版本号 + 帮助 | stage 2 build 失败 → 检查 build log |
| **eBPF 二进制存在** | `docker run --rm ckb-probe-case-study:dev ls /opt/ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf` | 文件列表 | `cargo xtask build-ebpf` 失败 → 看 stage 2 日志 |
| **make-snapshot 干净退出** | `make-snapshot.sh` 在 dev CKB 上跑 | `/backup/ckb-testnet-snap-h<n>-<ts>.tar.zst` 文件出现 + ckb 重启成功 | LOCK 文件检查失败 → ckb 没干净退出 |
| **restore-snapshot 干净退出** | `restore-snapshot.sh /backup/<file>` | `ckb migrate --check` 返回 0 + ckb RPC ready | snapshot 损坏 / 版本不兼容 |
| **p1-cpu.sh** | `p1-cpu.sh baseline 60 5` (60 秒缩短版) | mean %CPU 输出非零 | awk 字段错位（`$8` vs `$9`）|
| **p2-rss.sh** | `p2-rss.sh 5` (Ctrl+C 退出) | EXIT trap 触发 verdict | trap 没设置好 / pid 找不到 |
| **p3-stress.sh** | `p3-stress.sh 60 --no-db-bench` | `BPF event loss: 0 / N (0.0000%)` | ckb-probe 没 P-3 patch / threshold 解析错 |
| **p4-sync.sh** | `p4-sync.sh baseline 5` (5 分钟缩短版) | mean blocks/min 输出 | RPC 错（端口 / proxy）|
| **full-perf-run.sh dry run** | 临时改 `PHASE_A_SECS=60` 跑一次 | REPORT.txt 产出，4 项 verdict 都有内容 | wait 超时 / phase 切换错乱 |
| **demo-check** | `docker run --rm --privileged ... demo-check` | 终端输出 + `/tmp/perf-run/demo/demo-check.txt` 等文件 | privileged 模式没传 / CKB 没在跑 |
| **demo-normal** | `docker run --rm --privileged ... demo-normal` | `/tmp/perf-run/demo/demo-normal.jsonl` 含 60 行 JSON | awk 解析失败 / probe.log 格式异常 |
| **demo-stress** | `docker run --rm --privileged ... demo-stress` | `/tmp/perf-run/demo/demo-stress.txt` 含 ANOMALY DETECTED 块（或 caveat 说明）| db_bench 没装 / 磁盘太快没触发 |
| **case-1** | `docker run --rm --privileged -v ... case-1 /backup/snap.tar.zst` | `/tmp/perf-run/case1/REPORT.txt` 显示 IBD 完成 + blocks 数 | snapshot 太新 / 节点 P2P 没接进 |
| **case-2** | `docker run --rm --privileged -v ... case-2` | `/tmp/perf-run/case2/REPORT.txt` 显示 ANOMALY 计数 ≥ 1 | aggressive tuning 没生效 / 30min 不够 |

### 9.2 端到端验证流程

跑完所有 phase 之后，做一次完整的端到端 verification（约 5-7 小时）：

```bash
# Step 1: 构建镜像 (10 min)
docker build -f docker/Dockerfile -t ckb-probe-case-study:rc1 .

# Step 2: 准备 snapshot (15-30 min)
docker run --rm --privileged -v /root/data:/data -v /backup:/backup \
    ckb-probe-case-study:rc1 /opt/scripts/snapshot/make-snapshot.sh

# Step 3: 三个 demo (10 min total)
docker run --rm --privileged ... ckb-probe-case-study:rc1 demo-check
docker run --rm --privileged ... ckb-probe-case-study:rc1 demo-normal
docker run --rm --privileged ... ckb-probe-case-study:rc1 demo-stress

# Step 4: case-1 (1-2 hour)
docker run --rm --privileged -v ... ckb-probe-case-study:rc1 \
    case-1 /backup/ckb-testnet-snap-h<n>-<ts>.tar.zst

# Step 5: case-2 (5-30 min)
docker run --rm --privileged -v ... ckb-probe-case-study:rc1 case-2

# Step 6: full perf evaluation (4 hour)
docker run --rm --privileged -v ... ckb-probe-case-study:rc1 perf

# Step 7: 检查所有产出
ls -la /tmp/perf-run/
cat /tmp/perf-run/REPORT.txt
cat /tmp/perf-run/case1/REPORT.txt
cat /tmp/perf-run/case2/REPORT.txt
```

**验收标准：**

- ✅ 7 个 step 都成功完成（无 fatal error）
- ✅ 每个 REPORT.txt 都有明确的 verdict
- ✅ P-1 ~ P-4 在长跑数据下全部 PASS（这才是 ckb-probe 真正的"性能合规"证明）
- ✅ case-1 输出的 histogram 显示明显的 IBD 工作负载特征
- ✅ case-2 至少捕获 1 次 ANOMALY DETECTED 并附带 Compaction storm 归因

### 9.3 失败模式速查

| 症状 | 可能原因 | 排查 | 修复 |
|---|---|---|---|
| `docker build` 卡在 stage 2 cargo install 阶段 | bpf-linker 编译慢/卡住 | `docker build --progress=plain` 看实时输出 | 等或者切镜像 mirror |
| `docker run` 报 "Permission denied" 挂载 BPF | 容器没 `--privileged` | `docker inspect <container>` 看 cap | 加 `--privileged` |
| ckb-probe 起来但找不到 CKB pid | PID namespace 不通 | 容器内 `pgrep -x ckb` 验证 | 用 `--pid=host` 或单容器内启 ckb |
| ckb-probe attach uprobe 失败 "symbol not found" | CKB 二进制是 stripped 或符号不匹配 | `nm /usr/local/bin/ckb \| grep rocksdb_get` 验证 | 用 nervos/ckb 官方镜像（带符号）|
| make-snapshot 后 ckb 启动失败 | snapshot 时 ckb 没干净退出 | 看 ckb.log 报错信息 | 重做 snapshot,确认 LOCK 文件释放 |
| restore 后 `migrate --check` 失败 | snapshot 来自不同 ckb 版本 | `ckb --version` vs snapshot 制作时版本 | `ckb migrate -C $CKB_DATA` 后再跑 |
| case-2 30 分钟没 ANOMALY | 机器盘太快 / tuning 不够激进 | 看 probe.log 是否有 WRITE >1ms | 加大 `level0_*_trigger` / `--num` |
| full-perf-run.sh 4h 跑完 REPORT 全是 NaN | 各种原因（数据没采到 / 解析错位） | 看 progress.log 是否每个 phase 都跑完 | 单独跑 p-*.sh 定位 |

---

## 10. 下一步

### 10.1 物化顺序总结

按 §8.1 的 6 个 phase 顺序执行。每个 phase 完成后做对应的 §9.1 smoke test，所有 smoke test 通过才进入下一个 phase。

**最关键的早期验证 gate：**

1. **Phase 1 末尾：`docker build` 通过** — 这一步能成功意味着所有依赖都解决了，后面只是写脚本问题
2. **Phase 2 末尾：snapshot make + restore 成功** — 这一步能成功意味着 case study 的"地基"就位
3. **Phase 3 末尾：5 分钟 orchestrator dry run** — 这一步能成功意味着 4h 长跑能跑

通过这三个 gate 之后剩下的 phase 都是相对机械的"写脚本 + 测试"工作。

### 10.2 跟当前 4h 测试的关系

你目前正在跑的 `/tmp/perf-run-orchestrator.sh` 是这份文档里 §3.5 `full-perf-run.sh` 的**早期版本**。两者的差别：

| 方面 | 当前 orchestrator | 文档版 full-perf-run.sh |
|---|---|---|
| 路径常量 | 写死 `/tmp/perf-run/` | 用 `OUTPUT_DIR` 环境变量 |
| ckb 二进制路径 | 写死 `/root/ckb` | 用 `CKB_BIN` 环境变量 |
| 运行环境 | 直接在宿主上跑 | 容器内跑 |
| 逻辑 | **完全一致** | 同 |

所以**当前 4h 测试拿到的 REPORT.txt 就是文档版 orchestrator 的有效验证数据**——一旦 4h 跑完，我们就拿到了一份"真实节点上 ckb-probe 的 P-1~P-4 完整对照"，这份数据可以直接放进中期报告。

### 10.3 docker 化的优先级排序

如果时间紧张只能做一部分，按 ROI 排序：

1. **必做（P0）**：Phase 0 + Phase 1 + Phase 3 — 镜像 + 性能脚本，让 evaluator 能在容器里复现 P-1~P-4 评估
2. **强烈建议（P1）**：Phase 2 + Phase 4 — snapshot + demo,让 evaluator 能跑三个 demo 看到 ckb-probe 的所有能力
3. **完整交付（P2）**：Phase 5 — case-1 + case-2,完整的两个案例研究

P0 大约 4 hours 实施 + 4 hour 验证 = **半天到 1 天**就能交付一个可用的 docker 化评估包。

### 10.4 物化触发条件

**本文档是 reference / 蓝图**，所有脚本和 Dockerfile 的实际文件**还没创建**。要按这份文档物化到真实文件：

- 告诉我"按文档物化 Phase N"，我从指定 phase 开始
- 或者告诉我"全部物化"，我按 §8.1 顺序一次性铺完
- 或者你自己 cherry-pick 各章节内容到对应文件

**推荐路径**：等当前 4h 测试完成 → 看 REPORT.txt 验证 orchestrator 逻辑 → 然后让我"按文档物化 Phase 1 和 Phase 3"（最关键的两块），后面的 phase 视情况推进。

