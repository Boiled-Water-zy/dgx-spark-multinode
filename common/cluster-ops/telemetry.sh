#!/usr/bin/env bash
# telemetry —— 常驻遥测采集（优化点#4）。每 TELemetry_INTERVAL 秒把
# 温度/功耗/GPU利用率/显存/内存/loadavg 逐行 flush 写盘。
#
# 这是抓「过热硬关机」的唯一手段：热保护瞬间断电、业务日志来不及写，
# 但本采集器崩前最后一行就是压垮它的温度。做成 systemd service 常驻。
set -u
CFG=${CFG:-/etc/cluster-ops.env}
[ -r "$CFG" ] && . "$CFG"
: "${LOG_DIR:=/var/log/cluster-ops}"
INT=${TELEMETRY_INTERVAL:-10}
mkdir -p "$LOG_DIR"
F="$LOG_DIR/telemetry.log"
# 简单按天滚动，别无限长
while :; do
  ts=$(date '+%F %T')
  gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  load=$(cut -d' ' -f1-3 /proc/loadavg)
  mem=$(free -m | awk 'NR==2{printf "%d/%dMB", $3, $2}')
  echo "$ts gpu[T,W,%,memMB,totMB]=$gpu load=$load sysmem=$mem" >> "$F"
  # 保活：文件过大时截断保留尾部 20000 行
  lines=$(wc -l < "$F" 2>/dev/null || echo 0)
  [ "$lines" -gt 40000 ] && { tail -20000 "$F" > "$F.tmp" && mv "$F.tmp" "$F"; }
  sleep "$INT"
done
