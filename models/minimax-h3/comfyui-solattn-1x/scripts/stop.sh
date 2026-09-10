#!/usr/bin/env bash
set -euo pipefail
H3_ROOT="${H3_ROOT:-$HOME/minimax-h3}"
PIDF="$H3_ROOT/logs/comfyui.pid"
[ -f "$PIDF" ] || { echo "没有 pid 文件，可能没在跑"; exit 0; }
PID=$(cat "$PIDF")
kill "$PID" 2>/dev/null && echo "已停 $PID" || echo "进程 $PID 不在"
sleep 3; kill -9 "$PID" 2>/dev/null || true
rm -f "$PIDF"
