#!/usr/bin/env bash
# gpu-guard —— 主频封顶（优化点#2）。开机/手动跑一次，把 GPU 主频锁到 GPU_CLOCK_MAX，
# 压住持续满载发热，防过热硬关机。锁是驱动级、重启失效，所以做成开机 service。
#
# 实测（88+67，DS4 512K 上下文）：不锁频冲到 92-94°C 触发热保护硬断电、无日志；
# 锁 2800MHz 后只到 70°C，长上下文稳跑。GB10 是一体芯，nvidia-smi 无 -pl 功耗上限，
# 只能用 -lgc 锁频这一条软件手段。
set -u
CFG=${CFG:-/etc/cluster-ops.env}
[ -r "$CFG" ] && . "$CFG"
MAX=${GPU_CLOCK_MAX:-0}; MIN=${GPU_CLOCK_MIN:-0}
log(){ echo "[gpu-guard] $*"; }
[ "$MAX" = 0 ] || [ -z "$MAX" ] && { log "GPU_CLOCK_MAX 未设，跳过锁频"; exit 0; }
if nvidia-smi -lgc "${MIN:-0},$MAX" >/dev/null 2>&1; then
  log "已锁 GPU 主频 ${MIN:-0}-${MAX}MHz"
else
  log "锁频失败（nvidia-smi -lgc 不支持？）"; exit 1
fi
