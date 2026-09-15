#!/usr/bin/env bash
# crash-dump —— 崩溃现场采集（优化点#1）。supervisor 探到异常、动手重启前先跑一次，
# 把「为什么崩」的证据落盘，省得事后人肉 ssh 上去挖、且挖不到。
#
# 采集：两端容器日志尾部 + dmesg 尾部（找 OOM/NVRM/Link down）+ 当前温度/功耗。
# 注意：过热硬关机是瞬间断电、来不及写业务日志——那种靠 telemetry.sh 的连续采样兜底，
# 这里兜的是「机器还活着、只是服务崩了」的软崩（OOM / NCCL / Triton / rendezvous）。
set -u
CFG=${CFG:-/etc/cluster-ops.env}
[ -r "$CFG" ] && . "$CFG"
: "${LOG_DIR:=/var/log/cluster-ops}"; : "${CONTAINER:?}"; : "${SSH_USER:=ai}"
[ -r /run/cluster-rail.env ] && . /run/cluster-rail.env
PEER=${RAIL_PEER_IP:-${WORKER_RAIL_IP:-}}
mkdir -p "$LOG_DIR"
F="$LOG_DIR/crash-$(date +%Y%m%d-%H%M%S).log"
peer(){ ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$SSH_USER@${PEER}" "$@" 2>/dev/null; }

{
  echo "==== crash dump $(date -Is) 本机=$(hostname) ===="
  echo "---- 本机温度/功耗/利用率 ----"
  nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,memory.used --format=csv,noheader 2>/dev/null
  echo "---- 本机容器状态 ----"
  docker ps -a --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}} restarts?' 2>/dev/null
  docker inspect "$CONTAINER" --format 'restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' 2>/dev/null
  echo "---- 本机容器日志尾部(80) ----"
  docker logs "$CONTAINER" --tail 80 2>&1
  echo "---- 本机 dmesg 关键行(OOM/NVRM/Link/xid) ----"
  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|nvrm|xid|link down|i/o error|throttl' | tail -20
  if [ -n "$PEER" ]; then
    echo "==== 对端 $PEER ===="
    echo "---- 对端温度 ----"; peer 'nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu --format=csv,noheader'
    echo "---- 对端容器日志尾部(60) ----"; peer "docker logs $CONTAINER --tail 60 2>&1"
    echo "---- 对端 dmesg 关键行 ----"; peer "dmesg -T 2>/dev/null | grep -iE 'out of memory|nvrm|xid|link down|throttl' | tail -15"
  fi
  echo "==== end ===="
} > "$F" 2>&1
echo "[crash-dump] 现场已存 $F"
