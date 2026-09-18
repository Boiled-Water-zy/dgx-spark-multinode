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

# 0) 清残留：多网卡机器（一台插了两根光纤）上，MY_IP 可能同时残留在多块候选网卡上——
#    「已通不动网络」只认第一块命中的网卡，「保底」会遍历所有候选口都配一遍，「探测」对
#    「本来就在」的 IP 不清理，三处都会留下同 IP 多网卡的残局：内核路由/ARP 因此打架，
#    TCP 三次握手能走通、但对端看到的物理链路和预期不一致，NCCL/Gloo 握手数据错位，
#    表现为「连接已 ESTABLISHED 却永久卡死」（实测坑：断网复现时踩过，比「选错口」更隐蔽）。
#    每次运行先扫一遍，只留 ping 得通的那块，其余全部摘掉，后面的逻辑才有干净的起点。
ifs_with_ip=""
for ifname in $RAIL_CANDIDATES; do
  [ -e "/sys/class/net/$ifname" ] || continue
  ip -o -4 addr show "$ifname" | awk '{print $4}' | grep -q "^$MY_IP/" && ifs_with_ip="$ifs_with_ip $ifname"
done
if [ "$(echo $ifs_with_ip | wc -w)" -gt 1 ]; then
  keep=""
  for ifname in $ifs_with_ip; do
    [ -z "$keep" ] && ping -c1 -W2 -I "$ifname" "$PEER_IP" >/dev/null 2>&1 && keep=$ifname
  done
  for ifname in $ifs_with_ip; do
    [ "$ifname" = "$keep" ] && continue
    ip addr del "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
    log "清理多网卡同 IP 残留: $ifname（保留 ${keep:-无，等下面重新探测}）"
  done
fi

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
      ip addr add "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
    fi
    if ping -c1 -W2 -I "$ifname" "$PEER_IP" >/dev/null 2>&1; then
      log "第 $round 轮：$ifname 通了"; settle "$ifname"; exit 0; fi
    # 不管这次是不是自己 add 的，ping 不通就清掉——「本来就在」的 IP 若不清理，会在多网卡
    # 机器上留下同 IP 残留（见上面 0 号步骤的注释），这是之前反复复现同一坑的直接原因。
    ip addr del "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
  done
  log "第 $round 轮没通，等对端…"; sleep 10
done

# 3) 全试完仍不通：保底配在第一个有光的口，交给 supervisor 后续重试
for ifname in $RAIL_CANDIDATES; do
  [ "$(cat "/sys/class/net/$ifname/carrier" 2>/dev/null)" = 1 ] || continue
  ip link set "$ifname" up 2>/dev/null; ip addr add "$MY_IP/$RAIL_PREFIX" dev "$ifname" 2>/dev/null
  log "对端暂不可达，保底配在 $ifname"; settle "$ifname"; exit 0; done
log "没有任何光口有 carrier —— 检查光缆"; exit 1
