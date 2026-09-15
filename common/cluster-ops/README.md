# cluster-ops —— 双机推理集群运维层（master + worker）

给 DGX Spark（GB10）双机 TP=2 集群（DS4-Flash / GLM-5.3 / vision 等）加一层"部署即带日志、崩了能自愈、过热不硬崩"的运维层。基于 ybz21/dgx-spark-multinode 的 glm53 rail+supervise 设计，按现场实测补了 4 个优化点。

## 组成

| 文件 | 作用 |
|---|---|
| `ops.env` | 唯一配置：master/worker IP、光口候选、被监护容器名/端口/模型名、主频上限、节律 |
| `rail.sh` + `cluster-rail.{service,timer}` | 光口自适应：判据是"配上地址能 ping 通对端"（非 carrier）；**实测 RoCE v2 GID index 并写出**（优化点#3）。timer 每 60s 重探，支持热插拔/换口/GID 漂移 |
| `gpu-guard.sh` + `.service` | **GPU 主频封顶**（优化点#2）：`nvidia-smi -lgc`，压住持续满载发热。锁重启失效故做成开机 service |
| `telemetry.sh` + `.service` | **常驻遥测**（优化点#4）：每 10s 落盘温度/功耗/利用率/内存。抓过热硬关机前的最后现场 |
| `crash-dump.sh` | **崩溃现场采集**（优化点#1）：看门狗重启前 dump 两端容器日志+dmesg+温度 |
| `supervise.sh` + `.service` | 看门狗（仅 master）：真推理探针判活、有序重启（worker先/master后，<600s rendezvous）、指数退避、防抖；重启前依次 crash-dump→重探光口→重锁频 |
| `install.sh` | 在 master 跑一次，自动装两台 + 开机自启 + 持久化 journald |

## 4 个优化点（相对上游 glm53 脚本）

1. **崩溃现场留存**：上游探到崩只重启、不留证据，事后靠人肉 ssh 挖还常挖不到。现加 crash-dump（容器日志+dmesg+温度）+ 持久化 journald（重启后能查上次崩机前的系统日志）。
2. **热保护（主频锁）**：现场实测 DS4 512K 上下文不锁频冲到 92-94°C 触发热保护硬断电（无日志）；锁 2800MHz 只到 70°C。这是把"崩了自愈"升级成"根本不因热崩"。GB10 一体芯无 `-pl` 功耗上限，只能锁频。
3. **GID index 实测**：上游 rail 只探网口/HCA、没写 `NCCL_IB_GID_INDEX`。46/141 实测重启后 GID 表行号会漂移（5→6），容器 env 创建时烧死 → NCCL `ibv_modify_qp EINVAL` 崩环。现每次实测 RoCE v2 GID 写出。
4. **常驻遥测**：唯一能抓"瞬间断电"类硬崩的手段——崩前最后一行就是压垮它的温度。

## 用法

```bash
# 1) 改 ops.env：WORKER_HOST / CONTAINER / PORT / MODEL_ID / LAUNCH_CMD / GPU_CLOCK_MAX
# 2) master 上装（自动装 worker）：
sudo bash install.sh
# 3) 查看
tail -f /var/log/cluster-ops/telemetry.log
cat /run/cluster-rail.env
```

## 唯一重启权 + 卡死检测（重要设计）

- **supervisor 是集群唯一的重启权**：被监护容器的 docker 重启策略一律拨正为 `restart=no`（supervise 启动容器后强制 `docker update --restart=no`）。否则 docker 的 `unless-stopped` 会和 supervisor 抢——docker 只会原地无序重拉、不清显存孤儿、不重探 GID、不按 worker→master 顺序，崩溃后滚出显存孤儿导致新实例 CUDA OOM 死循环（实测 r=8）。supervisor 自身由 systemd `Restart=always`+开机自启保证常驻。
- **冷启动 vs 卡死**：光看时间窗（BOOT_GRACE）会把「卡在 NCCL 组网不动」误当「正在加载」而傻等十几分钟。supervise 以容器日志行数当进度指纹，`STALL_SEC`(默认300s) 内日志不再增长才判卡死→重启；日志在推进就继续等。

## 现场教训（88+67 部署 DS4-flash 实录）

- 光口配置**别写死**：从 46-141 拷来的 .env 写死 `enp1s0f1np1`，但 88/67 实际连的是 `enP2p1s0f0np0`（GID=3）→ GLOO `Unable to find address` 崩。rail 自适应正是为此。
- 双机启动**必须有序**（worker先/master后），手动 `docker restart` 两端会破坏 rendezvous → master 等不到 worker 崩循环。顺序逻辑固化在 supervise 一处。
- 旧模型的看门狗（如 ds4v-supervisor）会跟新部署抢端口，切换前先 `systemctl disable --now` 并清掉旧容器的 restart 策略。
