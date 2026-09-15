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

# ---------- 持久化 journald（优化点#4：重启后还能查上次崩机前的系统日志）----------
enable_persistent_journal(){
  local host_run="$1"
  $host_run 'mkdir -p /var/log/journal; F=/etc/systemd/journald.conf
    grep -q "^Storage=persistent" $F 2>/dev/null || { sed -i "s/^#\?Storage=.*/Storage=persistent/" $F || echo "Storage=persistent" >> $F; }
    grep -q "^SystemMaxUse=" $F 2>/dev/null || echo "SystemMaxUse=2G" >> $F
    systemctl restart systemd-journald'
}

say "master: 装脚本/配置/单元"
sudo install -m0644 "$CFG"                     /etc/cluster-ops.env
sudo install -m0755 "$HERE/rail.sh"            /usr/local/sbin/cluster-rail.sh
sudo install -m0755 "$HERE/gpu-guard.sh"       /usr/local/sbin/cluster-gpu-guard.sh
sudo install -m0755 "$HERE/telemetry.sh"       /usr/local/bin/cluster-telemetry.sh
sudo install -m0755 "$HERE/crash-dump.sh"      /usr/local/bin/cluster-crash-dump.sh
sudo install -m0755 "$HERE/supervise.sh"       /usr/local/bin/cluster-supervise.sh
sudo install -m0644 "$HERE"/systemd/cluster-*.service /etc/systemd/system/
sudo install -m0644 "$HERE"/systemd/cluster-*.timer   /etc/systemd/system/
sudo mkdir -p "${LOG_DIR:-/var/log/cluster-ops}"
# supervisor 免密调 rail/gpu-guard（重启前重探光口+重锁频）
echo "$SSH_USER ALL=(root) NOPASSWD: /usr/local/sbin/cluster-rail.sh, /usr/local/sbin/cluster-gpu-guard.sh" \
  | sudo tee /etc/sudoers.d/cluster-ops >/dev/null
sudo chmod 0440 /etc/sudoers.d/cluster-ops
enable_persistent_journal "sudo bash -c"
sudo systemctl daemon-reload
sudo systemctl enable --now cluster-rail.service cluster-rail.timer cluster-gpu-guard.service cluster-telemetry.service

say "worker: 装脚本/配置/单元（NODE_ROLE=worker，不装 supervisor）"
tar -C "$HERE" -cf - ops.env rail.sh gpu-guard.sh telemetry.sh crash-dump.sh systemd \
  | peer 'mkdir -p ~/cluster-ops && tar -C ~/cluster-ops -xf - && sed -i "s/^NODE_ROLE=.*/NODE_ROLE=worker/" ~/cluster-ops/ops.env'
peer 'sudo install -m0644 ~/cluster-ops/ops.env /etc/cluster-ops.env
      sudo install -m0755 ~/cluster-ops/rail.sh      /usr/local/sbin/cluster-rail.sh
      sudo install -m0755 ~/cluster-ops/gpu-guard.sh /usr/local/sbin/cluster-gpu-guard.sh
      sudo install -m0755 ~/cluster-ops/telemetry.sh /usr/local/bin/cluster-telemetry.sh
      sudo install -m0644 ~/cluster-ops/systemd/cluster-rail.service ~/cluster-ops/systemd/cluster-rail.timer \
                          ~/cluster-ops/systemd/cluster-gpu-guard.service ~/cluster-ops/systemd/cluster-telemetry.service /etc/systemd/system/
      sudo mkdir -p /var/log/cluster-ops
      sudo systemctl daemon-reload
      sudo systemctl enable --now cluster-rail.service cluster-rail.timer cluster-gpu-guard.service cluster-telemetry.service'
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
