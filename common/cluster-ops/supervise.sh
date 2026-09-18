#!/usr/bin/env bash
# supervise —— 双机看门狗 / 编排器（跑在 master 上）。
# 覆盖：整机重启、worker 崩溃、master 容器崩溃、光缆换口、软崩自愈。
#
# 相对上游 glm53-supervise 的增强：
#   - 优化点#1：动手重启前先 crash-dump 落盘现场（否则事后挖不到原因）
#   - 优化点#2：重启前重跑 gpu-guard 锁频（重启会丢锁）
#   - 优化点#3：重启前重跑 rail 重新实测光口/GID（换口/漂移自适应）
# 活性判据用真推理探针（1 token），不信 /health——worker 被 kill 后 /health 照样 200、
# 但真实请求挂死；先做便宜的结构检查（对端容器在不在）再发探针，故障发现快一个量级。
set -u
CFG=${CFG:-/etc/cluster-ops.env}; . "$CFG"
: "${LOG_DIR:=/var/log/cluster-ops}"; mkdir -p "$LOG_DIR"
RAIL=${RAIL:-/usr/local/sbin/cluster-rail.sh}
GUARD=${GUARD:-/usr/local/sbin/cluster-gpu-guard.sh}
DUMP=${DUMP:-/usr/local/bin/cluster-crash-dump.sh}
INTERVAL=${INTERVAL:-30}; PROBE_TIMEOUT=${PROBE_TIMEOUT:-60}
FAIL_LIMIT=${FAIL_LIMIT:-3}; BOOT_GRACE=${BOOT_GRACE:-1500}
backoff=60
log(){ echo "$(date -Is) [sup] $*"; }
peer(){ ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$SSH_USER@$WORKER_RAIL_IP" "$@"; }

healthy(){
  peer "docker ps -q --filter name=$CONTAINER --filter status=running" 2>/dev/null | grep -q . || return 1
  docker ps -q --filter "name=$CONTAINER" --filter status=running | grep -q . || return 1
  curl -s -m "$PROBE_TIMEOUT" "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":1,\"temperature\":0}" \
    2>/dev/null | grep -q '"choices"'
}

# 彻底清容器 + 杀残留 vllm 进程（root 助手；docker rm 不杀 VLLM::Worker，
# 攒下 85GB 孤儿 → 新实例 Cuda OOM）。$1=peer 则清对端。
CLEAN=${CLEAN:-/usr/local/sbin/cluster-clean.sh}
clean_node(){
  if [ "${1:-}" = peer ]; then peer "sudo -n $CLEAN" 2>/dev/null; else sudo -n "$CLEAN"; fi
}

# 把 rail 实测的 NCCL 值（IFNAME/HCA/GID，可能因重启漂移）同步进 .env.dspark，
# 每台用自己的 /run/cluster-rail.env。不做这步 → 启动仍读旧 GID → NCCL 崩环（实测坑）。
DEPLOY_ENV=${DEPLOY_ENV:-/home/ai/ds4-dspark-2x/.env.dspark}
_SYNC='. /run/cluster-rail.env 2>/dev/null; [ -n "$RAIL_GID_INDEX" ] && sed -i "s/^NCCL_IB_GID_INDEX=.*/NCCL_IB_GID_INDEX=$RAIL_GID_INDEX/; s/^NCCL_IB_HCA=.*/NCCL_IB_HCA=$RAIL_HCA/; s/^NCCL_SOCKET_IFNAME=.*/NCCL_SOCKET_IFNAME=$RAIL_IF/" '"$DEPLOY_ENV"
apply_rail(){ bash -c "$_SYNC"; peer "$_SYNC"; }

restart_cluster(){
  log "== 有序重启 =="
  "$DUMP" 2>/dev/null || log "crash-dump 返回非零（继续）"     # #1 先存现场
  sudo -n "$RAIL"  || log "rail 返回非零（继续）"               # #3 重探光口/GID
  sudo -n "$GUARD" || log "gpu-guard 返回非零（继续）"          # #2 重锁主频
  peer "sudo -n $RAIL; sudo -n $GUARD" 2>/dev/null || true      # 对端也重探+重锁
  clean_node                                                   # 清 master 容器+孤儿进程
  clean_node peer || log "worker 暂不可达"                      # 清 worker
  for i in $(seq 1 30); do peer true >/dev/null 2>&1 && break; sleep 10; done
  peer true >/dev/null 2>&1 || { log "worker 不可达，本轮放弃"; return 1; }
  apply_rail; log "已同步 rail 实测 NCCL 值到两端 .env（防 GID 漂移）"   # 关键：启动前把 GID 喂进去
  # 有序：worker(rank1) 先，master(rank0) 后，间隔 < 600s rendezvous
  log "起 worker rank1"; peer "$WORKER_LAUNCH" || { log "worker 启动失败"; return 1; }
  log "起 master rank0"; bash -lc "$MASTER_LAUNCH" || { log "master 启动失败"; return 1; }
  # supervisor 是唯一重启权：把容器 docker 重启策略强制改 no，杜绝 docker 无序重拉与本脚本抢、
  # 滚出显存孤儿→OOM（实测坑）。无论模型 compose 里写的什么策略，这里都拨正。
  docker update --restart=no "$CONTAINER" >/dev/null 2>&1
  peer "docker update --restart=no $CONTAINER" >/dev/null 2>&1
  for i in $(seq 1 $((BOOT_GRACE/10))); do
    healthy && { log "healthy"; return 0; }
    docker ps -q --filter "name=$CONTAINER" | grep -q . || { log "master 容器退出"; return 1; }
    sleep 10
  done
  log "超 ${BOOT_GRACE}s 未 healthy"; return 1
}

# 冷启动 vs 死亡判定：容器在跑且启动未超 BOOT_GRACE = 冷启动中（DS4 1M 冷编译要 10-15 分钟），
# 健康检查没过属正常，耐心等、不算失败、绝不重启；只有「容器退出/不见了」或「跑了超过 BOOT_GRACE
# 仍不健康（=卡死）」才判死、进失败计数。这样不会误杀正在加载的好实例。
master_running(){ docker ps -q --filter "name=$CONTAINER" --filter status=running | grep -q .; }
master_uptime(){ # 容器已启动秒数；容器不存在返回大数（当死处理）
  local s; s=$(docker inspect "$CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null)
  [ -z "$s" ] && { echo 999999; return; }
  echo $(( $(date +%s) - $(date -d "$s" +%s 2>/dev/null || echo 0) ))
}

# 冷启动是否「还在推进」：用容器日志行数当进度指纹，推进就刷新时间戳。
# 只有「日志连续 STALL_SEC 秒不再增长」才判为卡死——把「真加载(要等)」和「卡死(该重启)」
# 区分开。否则卡在 NCCL 组网不动时，仅按 BOOT_GRACE 时间窗会傻等十几分钟才动手（实测坑）。
STALL_SEC=${STALL_SEC:-300}
_last_lines=0; _last_move=$(date +%s)
log_progressing(){
  # 死亡标志：这些行出现说明已崩/卡死，但日志行数还在涨(报错/关闭刷屏)会骗过"行数增长=推进"。
  #   - "No available shared memory broadcast block"：worker 失联、master engine 空等
  #   - "EngineDeadError" / "EngineCore encountered an issue"：vLLM engine 崩(容器可能还 Up、8888 已 refused)
  #   - "Application shutdown complete"：APIServer 已退出
  # 命中任一直接判不推进 → 走卡死重启(含 crash-dump 留现场)，别被骗当成冷启动傻等(实测坑)。
  docker logs "$CONTAINER" 2>&1 | tail -5 | grep -qE "No available shared memory broadcast block|EngineDeadError|EngineCore encountered an issue|Application shutdown complete" && return 1
  local n; n=$(docker logs "$CONTAINER" 2>&1 | wc -l 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt "$_last_lines" ]; then _last_lines=$n; _last_move=$(date +%s); return 0; fi
  [ $(( $(date +%s) - _last_move )) -lt "$STALL_SEC" ]   # 仍在停滞窗口内=还算推进
}

log "supervisor 启动: container=$CONTAINER port=$PORT model=$MODEL_ID"
fails=0
while :; do
  if healthy; then
    [ "$fails" -gt 0 ] && log "恢复正常"; fails=0; backoff=60
  elif master_running && [ "$(master_uptime)" -lt "$BOOT_GRACE" ] && log_progressing; then
    # 冷启动中且日志仍在推进：正常加载，耐心等（不算失败）
    log "冷启动中（up $(master_uptime)s，日志推进中），等待"
    fails=0
  else
    # 容器退出/不见了，或超 BOOT_GRACE，或日志停滞 >${STALL_SEC}s（卡死）= 真死
    fails=$((fails+1))
    log "判定异常 $fails/$FAIL_LIMIT（running=$(master_running && echo y || echo n) up=$(master_uptime)s 停滞=$(( $(date +%s) - _last_move ))s）"
    if [ "$fails" -ge "$FAIL_LIMIT" ]; then
      if restart_cluster; then log "重启成功"; fails=0; backoff=60; _last_lines=0; _last_move=$(date +%s)
      else log "重启失败，退避 ${backoff}s"; sleep "$backoff"; backoff=$(( backoff*2>600 ? 600 : backoff*2 )); fi
    fi
  fi
  sleep "$INTERVAL"
done
