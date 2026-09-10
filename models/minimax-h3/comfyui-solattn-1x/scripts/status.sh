#!/usr/bin/env bash
set -euo pipefail
H3_ROOT="${H3_ROOT:-$HOME/minimax-h3}"
PORT="${COMFY_PORT:-8188}"
PIDF="$H3_ROOT/logs/comfyui.pid"

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "进程: 运行中 pid=$(cat "$PIDF")"
else
  echo "进程: 未运行"
fi

if curl -s -m 5 "http://127.0.0.1:$PORT/system_stats" -o /tmp/h3_stats.json; then
  python3 - /tmp/h3_stats.json <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
dev = d["devices"][0]
print(f"接口: ComfyUI {d['system']['comfyui_version']} · {dev['name']} · "
      f"free {dev['vram_free'] / 2**30:.1f} GiB / {dev['vram_total'] / 2**30:.1f} GiB")
PYEOF
else
  echo "接口: 不通"
fi

curl -s -m 5 "http://127.0.0.1:$PORT/queue" -o /tmp/h3_queue.json 2>/dev/null \
  && python3 -c "
import json
q = json.load(open('/tmp/h3_queue.json'))
print(f\"队列: running={len(q.get('queue_running', []))} pending={len(q.get('queue_pending', []))}\")"

echo "产物: $(ls -1 "$H3_ROOT/comfy/ComfyUI/output/video" 2>/dev/null | wc -l) 个 ($H3_ROOT/comfy/ComfyUI/output/video)"
free -g | sed -n '1,2p'
