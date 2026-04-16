#!/usr/bin/env bash
#
# entrypoint.sh — dispatcher for ckb-probe case study container.
#
# Subcommands:
#   help            show usage and README
#   bash            drop into interactive shell
#   start-ckb       start CKB in background (idempotent)
#   demo-check      run ckb-probe check + symbols (read-only)
#   demo-normal     capture 5 minutes of normal monitoring as JSON
#   demo-table      default stats table mode
#   demo-histogram  latency distribution histogram mode
#   demo-slow       slow operations capture mode
#   demo-stress     inject db_bench load and watch ckb-probe react
#   case-1          IBD write pattern case study
#   case-2          compaction storm case study
#   perf            full P-1~P-4 evaluation (4 hours)
#   p3-stress       standalone P-3 event loss test
#   stability       48h stability test (S-1~S-4)
#   stability-report  generate stability report from data

set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
    help)
        cat /opt/README.md 2>/dev/null || true
        cat <<'USAGE'

Usage:
    docker run ... ckb-probe help
    docker run ... ckb-probe bash
    docker run ... ckb-probe start-ckb
    docker run ... ckb-probe demo-check
    docker run ... ckb-probe demo-normal [seconds]
    docker run ... ckb-probe demo-table [seconds]
    docker run ... ckb-probe demo-histogram [seconds]
    docker run ... ckb-probe demo-slow [seconds] [threshold_us]
    docker run ... ckb-probe demo-stress [num_entries]
    docker run ... ckb-probe case-1 [max_seconds]
    docker run ... ckb-probe case-2
    docker run ... ckb-probe perf
    docker run ... ckb-probe p3-stress [seconds]
    docker run ... ckb-probe stability
    docker run ... ckb-probe stability-report [data_dir]

Required volumes:
    -v /host/ckb-data:/data         CKB chain data directory
    -v /host/output:/tmp/perf-run   evaluation output
    -v /root/ckb:/root/ckb:ro       CKB binary (path must match host exe)

Required capabilities:
    --privileged --pid host
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
    demo-table)
        exec /opt/scripts/demo/demo-table.sh "$@"
        ;;
    demo-histogram)
        exec /opt/scripts/demo/demo-histogram.sh "$@"
        ;;
    demo-slow)
        exec /opt/scripts/demo/demo-slow.sh "$@"
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
        exec /opt/scripts/perf/perf-run-orchestrator.sh "$@"
        ;;
    p3-stress)
        exec /opt/scripts/perf/p3-stress.sh "$@"
        ;;
    stability)
        exec /opt/scripts/stability/stability-48h.sh "$@"
        ;;
    stability-report)
        exec /opt/scripts/stability/generate-report.sh "$@"
        ;;
    *)
        exec "$CMD" "$@"
        ;;
esac
