#!/usr/bin/env bash
# clean —— 彻底清理推理容器 + 残留 vllm 进程（root）。供 supervisor 重启前调用。
# 今天实测坑：docker rm 不杀容器内 VLLM::Worker，攒下 85GB 孤儿 → 新实例 Cuda OOM。
# 所以删容器后必须 pkill 残留 vllm 进程 + 兜底杀 nvidia-smi 里还占显存的 pid。
set -u
CFG=${CFG:-/etc/cluster-ops.env}; [ -r "$CFG" ] && . "$CFG"
: "${CONTAINER:?}"
docker rm -f "$CONTAINER" >/dev/null 2>&1
sleep 2
pkill -9 -f 'VLLM::' 2>/dev/null
pkill -9 -f 'vllm serve' 2>/dev/null
for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 3
echo "[clean] 剩余GPU进程: $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -c . || echo 0) 系统内存: $(free -g | awk 'NR==2{print $3"/"$2"G"}')"
