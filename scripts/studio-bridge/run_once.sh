#!/usr/bin/env bash
# studio-bridge 心跳一次：先回收上一轮结果，再发新任务书。
# 幂等、可任意频率重跑；适合挂 cron 或作为 automation 的一步。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REG=${1:-"$HERE/registry.json"}
LOG=${2:-"$HOME/.dsh/logs/studio-bridge-$(date +%F).log"}
mkdir -p "$(dirname "$LOG")"
{
  echo "===== $(date '+%F %T') bridge tick ====="
  echo "--- collect ---"
  python3 "$HERE/collect.py" "$REG"
  echo "--- dispatch ---"
  python3 "$HERE/dispatch.py" "$REG"
  echo "--- summary ---"
  python3 "$HERE/status_report.py" "$REG"
} >> "$LOG" 2>&1
rc=$?
tail -40 "$LOG" | sed 's/^/  /'
exit $rc
