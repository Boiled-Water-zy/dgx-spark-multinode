#!/usr/bin/env bash
# rail —— 光口自适应 + GID 实测。插上哪个 QSFP 口都能自动认出来、配好地址、
# 并把 NCCL 需要的 IFNAME / HCA / GID_INDEX 写出来给 launcher 和 supervisor 用。
#
# 判据是「配上地址后 ping 得通对端」，不是「有没有光」——两对口都插缆时 carrier 都是 1，
# 只有一对真连着对端。幂等：已通就不动网络。
#
# 优化点#3（相对上游 glm53-rail）：实测 RoCE v2 的 GID index 并写入。
# 踩过的坑：重启后 GID 表行号会漂移（46/141 上从 5 挪到 6），容器 env 是创建时烧死的，
# 用错 GID → NCCL ibv_modify_qp EINVAL 崩环。所以每次都实测，不写死。
set -u
CFG=${CFG:-/etc/cluster-ops.env}
[ -r "$CFG" ] && . "$CFG"
: "${RAIL_CANDIDATES:=enP2p1s0f0np0 enp1s0f1np1 enp1s0f0np0 enP2p1s0f1np1}"
: "${RAIL_PREFIX:=24}"
OUT=${RAIL_OUT:-/run/cluster-rail.env}
log(){ echo "[rail] $*"; }

# --- 自认角色 ---
ROLE=${NODE_ROLE:-${ROLE:-}}
case "$ROLE" in
  master|head) ROLE=master; MY_IP=$MASTER_RAIL_IP; PEER_IP=$WORKER_RAIL_IP ;;
  worker|slave) ROLE=worker; MY_IP=$WORKER_RAIL_IP; PEER_IP=$MASTER_RAIL_IP ;;
  *) log "无法确认角色（NODE_ROLE=$ROLE）"; exit 2 ;;
esac
log "role=$ROLE 自己=$MY_IP 对端=$PEER_IP"

hca_of(){ local ifname=$1 d
  for d in /sys/class/infiniband/*/device/net/"$ifname"; do
    [ -e "$d" ] && basename "$(dirname "$(dirname "$(dirname "$d")")")" && return 0
  done; return 1; }

# 实测 RoCE v2 + 本机 IPv4 映射的 GID index。IPv4-mapped GID 尾部是 ffff:XXXX:XXXX。
gid_index_of(){ local hca=$1 ip=$2 idx gid typ
  # 把 10.0.0.2 转成 ffff:0a00:0002 的尾巴
  local o1 o2 o3 o4; IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  local tail; tail=$(printf 'ffff:%02x%02x:%02x%02x' "$o1" "$o2" "$o3" "$o4")
  for idx in $(seq 0 15); do
    gid=$(cat "/sys/class/infiniband/$hca/ports/1/gids/$idx" 2>/dev/null) || continue
    typ=$(cat "/sys/class/infiniband/$hca/ports/1/gid_attrs/types/$idx" 2>/dev/null) || continue
    case "$gid" in *"$tail") [ "$typ" = "RoCE v2" ] && { echo "$idx"; return 0; } ;; esac
  done
  echo 3; return 1   # 探不到用 CX7 常见值兜底
}

emit(){ local ifname=$1 hca=$2 gid=$3
  { echo "RAIL_IF=$ifname"; echo "RAIL_HCA=$hca"; echo "RAIL_GID_INDEX=$gid"
    echo "RAIL_ROLE=$ROLE"; echo "RAIL_MY_IP=$MY_IP"; echo "RAIL_PEER_IP=$PEER_IP"; } > "$OUT"
  log "就绪: if=$ifname hca=$hca gid=$gid -> $OUT"; }

settle(){ local ifname=$1 hca gid; hca=$(hca_of "$ifname" || echo unknown)
  gid=$(gid_index_of "$hca" "$MY_IP"); emit "$ifname" "$hca" "$gid"; }

# 1) 当前已通 → 不动网络
cur=$(ip -o -4 addr show | awk -v ip="$MY_IP/" '$4 ~ "^"ip {print $2; exit}')
if [ -n "$cur" ] && ping -c1 -W2 -I "$cur" "$PEER_IP" >/dev/null 2>&1; then
  log "已通（$cur），不动网络"; settle "$cur"; exit 0; fi

# NM unmanaged 后开机光口无人 up、operstate=down、carrier=0，下面 carrier 判据会把所有口跳过。
# 先把候选口都 up 起来、给 link 协商时间，再探测（否则 rail 永远配不上、supervisor 空等）。
for ifname in $RAIL_CANDIDATES; do [ -e "/sys/class/net/$ifname" ] && ip link set "$ifname" up 2>/dev/null; done
sleep 4

# 2) 逐个候选口试：配地址 → ping 对端（对端可能开机慢，整轮重试）
for round in 1 2 3 4 5 6; do
  for ifname in $RAIL_CANDIDATES; do
    [ -e "/sys/class/net/$ifname" ] || continue
    [ "$(cat "/sys/class/net/$ifname/carrier" 2>/dev/null)" = 1 ] || continue
    if ! ip -o -4 addr show "$ifname" | awk '{print $4}' | grep -q "^$MY_IP/"; then
      ip link set "$ifname" up 2>/dev/null
      ip addr add "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null; added=1
    else added=0; fi
    if ping -c1 -W2 -I "$ifname" "$PEER_IP" >/dev/null 2>&1; then
      log "第 $round 轮：$ifname 通了"; settle "$ifname"; exit 0; fi
    [ "$added" = 1 ] && ip addr del "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
  done
  log "第 $round 轮没通，等对端…"; sleep 10
done

# 3) 全试完仍不通：保底配在第一个有光的口，交给 supervisor 后续重试
for ifname in $RAIL_CANDIDATES; do
  [ "$(cat "/sys/class/net/$ifname/carrier" 2>/dev/null)" = 1 ] || continue
  ip link set "$ifname" up 2>/dev/null; ip addr add "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
  log "对端暂不可达，保底配在 $ifname"; settle "$ifname"; exit 0; done
log "没有任何光口有 carrier —— 检查光缆"; exit 1
