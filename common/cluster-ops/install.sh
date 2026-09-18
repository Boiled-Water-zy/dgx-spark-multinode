#!/usr/bin/env bash
# 把 cluster-ops 运维层装到两台（master + worker）。在 master 上跑一次，自动装 worker 侧。
# 幂等，可重复执行。装完：光口自适应 + GPU主频锁 + 常驻遥测 + 看门狗自愈 + 崩溃现场留存，全部开机自启。
#
# 用法: sudo bash install.sh            # 读同目录 ops.env
#       CFG=/path/ops.env sudo bash install.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CFG=${CFG:-$HERE/ops.env}
[ -f "$CFG" ] || { echo "先把 ops.env.example 复制为 ops.env 并按你的集群修改"; exit 1; }
. "$CFG"
: "${WORKER_HOST:?}" "${SSH_USER:=ai}"
peer(){ ssh -o StrictHostKeyChecking=no "$SSH_USER@$WORKER_HOST" "$@"; }
say(){ echo -e "\n== $* =="; }

# 光口列表（来自 ops.env 的 RAIL_CANDIDATES），供 NM unmanaged 用
: "${RAIL_CANDIDATES:=enp1s0f1np1 enP2p1s0f1np1 enp1s0f0np0 enP2p1s0f0np0}"
NM_UNMANAGED=$(for i in $RAIL_CANDIDATES; do printf "interface-name:%s;" "$i"; done)

# ---------- master→worker ssh 免密 ----------
# supervise 的 peer() 运行期走 WORKER_RAIL_IP（光纤）、install 走 WORKER_HOST（管理网），
# 两个地址是同一台 worker、authorized_keys 共享。没免密则 supervise 探 worker 失败→误判重启。
ensure_peer_key(){
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
  for t in "$WORKER_HOST" "${WORKER_RAIL_IP:-}"; do
    [ -n "$t" ] || continue
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$t" true 2>/dev/null \
      || ssh-copy-id -o StrictHostKeyChecking=no "$SSH_USER@$t" 2>/dev/null \
      || echo "  ! 未能自动配到 $t 免密，请手动 ssh-copy-id $SSH_USER@$t 后重跑"
  done
}

# ---------- NM unmanaged 光口 ----------
# 否则 NetworkManager 的 DHCP「有线连接」profile 会在重启后抢管光口、用 DHCP 覆盖掉
# rail 配的静态 10.0.0.x，导致 supervise 探 worker 失败/双机组网断。让 NM 永久不管光口。
setup_nm_unmanaged(){
  $1 "mkdir -p /etc/NetworkManager/conf.d
      printf '[keyfile]\nunmanaged-devices=%s\n' '$NM_UNMANAGED' > /etc/NetworkManager/conf.d/99-cluster-fiber-unmanaged.conf
      nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true"
}

# ---------- 持久化 journald（优化点#4：重启后还能查上次崩机前的系统日志）----------
enable_persistent_journal(){
  local host_run="$1"
  $host_run 'mkdir -p /var/log/journal; F=/etc/systemd/journald.conf
    grep -q "^Storage=persistent" $F 2>/dev/null || { sed -i "s/^#\?Storage=.*/Storage=persistent/" $F || echo "Storage=persistent" >> $F; }
    grep -q "^SystemMaxUse=" $F 2>/dev/null || echo "SystemMaxUse=2G" >> $F
    systemctl restart systemd-journald'
}

say "配 master→worker ssh 免密（supervise peer 用）"
ensure_peer_key

say "master: 装脚本/配置/单元"
sudo install -m0644 "$CFG"                     /etc/cluster-ops.env
sudo install -m0755 "$HERE/rail.sh"            /usr/local/sbin/cluster-rail.sh
sudo install -m0755 "$HERE/gpu-guard.sh"       /usr/local/sbin/cluster-gpu-guard.sh
sudo install -m0755 "$HERE/clean.sh"           /usr/local/sbin/cluster-clean.sh
sudo install -m0755 "$HERE/telemetry.sh"       /usr/local/bin/cluster-telemetry.sh
sudo install -m0755 "$HERE/crash-dump.sh"      /usr/local/bin/cluster-crash-dump.sh
sudo install -m0755 "$HERE/supervise.sh"       /usr/local/bin/cluster-supervise.sh
sudo install -m0644 "$HERE"/systemd/cluster-*.service /etc/systemd/system/
sudo install -m0644 "$HERE"/systemd/cluster-*.timer   /etc/systemd/system/
# 属主必须是 $SSH_USER：supervisor/crash-dump/telemetry 都以 User=ai 跑，root:root 目录
# 会让它们建文件静默失败（crash-dump.sh 还会把失败误报成功，双重坑，实测踩过）。
sudo install -d -o "$SSH_USER" -g "$SSH_USER" -m0755 "${LOG_DIR:-/var/log/cluster-ops}"
# supervisor(User=ai) 免密调 rail/gpu-guard/clean（重启前重探光口+重锁频+清孤儿）
echo "$SSH_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-rail.sh, /usr/local/sbin/cluster-gpu-guard.sh, /usr/local/sbin/cluster-clean.sh" \
  | sudo tee /etc/sudoers.d/cluster-ops >/dev/null
sudo chmod 0440 /etc/sudoers.d/cluster-ops
setup_nm_unmanaged "sudo bash -c"
enable_persistent_journal "sudo bash -c"
sudo systemctl daemon-reload
sudo systemctl enable --now cluster-rail.service cluster-rail.timer cluster-gpu-guard.service cluster-telemetry.service

say "worker: 装脚本/配置/单元（NODE_ROLE=worker，不装 supervisor）"
tar -C "$HERE" -cf - ops.env rail.sh gpu-guard.sh clean.sh telemetry.sh crash-dump.sh systemd \
  | peer 'mkdir -p ~/cluster-ops && tar -C ~/cluster-ops -xf - && sed -i "s/^NODE_ROLE=.*/NODE_ROLE=worker/" ~/cluster-ops/ops.env'
peer "sudo install -m0644 ~/cluster-ops/ops.env /etc/cluster-ops.env
      sudo install -m0755 ~/cluster-ops/rail.sh      /usr/local/sbin/cluster-rail.sh
      sudo install -m0755 ~/cluster-ops/gpu-guard.sh /usr/local/sbin/cluster-gpu-guard.sh
      sudo install -m0755 ~/cluster-ops/clean.sh     /usr/local/sbin/cluster-clean.sh
      sudo install -m0755 ~/cluster-ops/telemetry.sh /usr/local/bin/cluster-telemetry.sh
      sudo install -m0644 ~/cluster-ops/systemd/cluster-rail.service ~/cluster-ops/systemd/cluster-rail.timer \
                          ~/cluster-ops/systemd/cluster-gpu-guard.service ~/cluster-ops/systemd/cluster-telemetry.service /etc/systemd/system/
      sudo install -d -o '$SSH_USER' -g '$SSH_USER' -m0755 /var/log/cluster-ops
      echo '$SSH_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-rail.sh, /usr/local/sbin/cluster-gpu-guard.sh, /usr/local/sbin/cluster-clean.sh' | sudo tee /etc/sudoers.d/cluster-ops >/dev/null
      sudo chmod 0440 /etc/sudoers.d/cluster-ops
      sudo systemctl daemon-reload
      sudo systemctl enable --now cluster-rail.service cluster-rail.timer cluster-gpu-guard.service cluster-telemetry.service"
setup_nm_unmanaged "peer sudo bash -c"
enable_persistent_journal "peer sudo bash -c"

say "master: 启用看门狗"
sudo systemctl enable --now cluster-supervisor.service

cat <<TIP

装好了。查看:
  systemctl status cluster-supervisor --no-pager
  tail -f /var/log/cluster-ops/supervisor.log      # 看门狗
  tail -f /var/log/cluster-ops/telemetry.log       # 温度/功耗曲线
  ls /var/log/cluster-ops/crash-*.log              # 崩溃现场（如有）
  cat /run/cluster-rail.env                         # 探到的光口/HCA/GID
TIP
