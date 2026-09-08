#!/usr/bin/env bash
# 启动/重启 ComfyUI (MiniMax-H3)
set -euo pipefail
H3_ROOT="${H3_ROOT:-$HOME/minimax-h3}"
COMFY="$H3_ROOT/comfy/ComfyUI"
PY="$H3_ROOT/comfy/venv/bin/python"
PORT="${COMFY_PORT:-8188}"
LOG="$H3_ROOT/logs"; mkdir -p "$LOG"
PIDF="$LOG/comfyui.pid"

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "停止旧进程 $(cat "$PIDF")"; kill "$(cat "$PIDF")"; sleep 5
  kill -9 "$(cat "$PIDF")" 2>/dev/null || true
fi

cd "$COMFY"
# GB10 统一内存：不要预留显存上限，让 ComfyUI 按需分配
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
nohup "$PY" main.py --listen 0.0.0.0 --port "$PORT" \
  --output-directory "$COMFY/output" \
  > "$LOG/comfyui.log" 2>&1 &
echo $! > "$PIDF"
echo "ComfyUI 启动中 pid=$(cat "$PIDF")  http://$(hostname -I | awk '{print $1}'):$PORT"
echo "日志: tail -f $LOG/comfyui.log"
