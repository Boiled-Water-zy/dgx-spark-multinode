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
  # 有序：worker(rank1) 先，master(rank0) 后，间隔 < 600s rendezvous
  log "起 worker rank1"; peer "$WORKER_LAUNCH" || { log "worker 启动失败"; return 1; }
  log "起 master rank0"; bash -lc "$MASTER_LAUNCH" || { log "master 启动失败"; return 1; }
  for i in $(seq 1 $((BOOT_GRACE/10))); do
    healthy && { log "healthy"; return 0; }
    docker ps -q --filter "name=$CONTAINER" | grep -q . || { log "master 容器退出"; return 1; }
    sleep 10
  done
  log "超 ${BOOT_GRACE}s 未 healthy"; return 1
}

log "supervisor 启动: container=$CONTAINER port=$PORT model=$MODEL_ID"
fails=0
while :; do
  if healthy; then
    [ "$fails" -gt 0 ] && log "恢复正常"; fails=0; backoff=60
  else
    fails=$((fails+1)); log "健康检查失败 $fails/$FAIL_LIMIT"
    if [ "$fails" -ge "$FAIL_LIMIT" ]; then
      if restart_cluster; then log "重启成功"; fails=0; backoff=60
      else log "重启失败，退避 ${backoff}s"; sleep "$backoff"; backoff=$(( backoff*2>600 ? 600 : backoff*2 )); fi
    fi
  fi
  sleep "$INTERVAL"
done
