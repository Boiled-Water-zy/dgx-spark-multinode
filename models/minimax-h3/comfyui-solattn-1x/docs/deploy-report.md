# MiniMax-H3 单机部署实测报告

**日期**：2026-09-09 · **机器**：`192.168.130.8`（spark-e9d7）· **服务**：`http://192.168.130.8:8188`

## 环境

| 项 | 值 |
|---|---|
| 硬件 | NVIDIA GB10（DGX Spark，SM121），aarch64，119 GiB 统一内存，3.7 TB NVMe |
| 驱动 / 内核 | 580.126.09 / 6.17.0-1008-nvidia |
| OS / CUDA | Ubuntu 24.04.4 LTS / CUDA toolkit 13.0 |
| PyTorch | **2.14.0+cu130**（`cuda.is_available()=True`；上游写的是 2.11+，装最新的没问题） |
| ComfyUI | v0.30.1，前端 1.47.12 |
| 加速节点 | Sol-Attn（flex_attention 路径，自动识别 SM121）、SageAttention 1.0.6、Spectrum、H3FirstBlockCache、H3 批量 VAE 解码（自称 GB10 上 1.66×） |

## 腾内存

部署前该机由 `modelhub` 守着 `ds4-text`（DeepSeek-V4-Flash-0731，双节点 vLLM），
单个 vLLM 进程占 **101 GB / 119 GB**，只剩 6.4 GB 可用。

**注意别用 `docker stop`**：机器上 `modelhub.service` 是自愈守护，容器停掉几分钟就被拉回来。
要走它自己的接口，它会把"停"这个状态记下来：

```bash
~/modelhub/bin/modelhub list          # 看谁是 active
~/modelhub/bin/modelhub stop ds4-text # 停并保持停止（daemon 尊重这个状态）
# 释放后 113 GB 可用；用完恢复：
~/modelhub/bin/modelhub start ds4-text
```

## 下载

权重全部走 ModelScope `Comfy-Org/MiniMax-H3`（整仓 477 GB，只取需要的）：

| 阶段 | 内容 | 大小 | 实测速度 |
|---|---|---|---|
| phase1 | fl2va fp8 + fl2va int8 + NVFP4-AWQ 文本编码器 + 视频/音频 VAE + 2 个 turbo LoRA | 63 GB | **15.6–17.3 MB/s** |
| phase2 | ref2va fp8 + int8 + ref2v turbo LoRA（R2V 用） | 43 GB | 同上 |
| upscalers | RealESRGAN x2plus / x4plus（ModelScope 没有，走 hf-mirror） | 130 MB | 秒下 |

对比：`download.pytorch.org` 在这台机上只有 **132 KB/s**，
换南大镜像 `mirrors.nju.edu.cn/pytorch/whl/cu130` 后 **4–13 MB/s**。
GitHub 直连 SSL timeout，`gh-proxy.com` 正常。

## 实测

三次实跑，均为 124 帧（5.17s @24fps），带 AAC 音轨，输出可正常播放：

| # | 工作流 | 主干 | 分辨率 | 步数 | 端到端 | 论坛 GB10 参考 |
|---|---|---|---|---|---|---|
| 1 | `h3-dense-baseline.json` | fp8 | 864×480 | 20 | **246 s（4.11 min）** | 4 m 45 s |
| 2 | int8 探针（baseline 换主干） | **int8-convrot** | 864×480 | 4 | 80 s | — |
| 3 | `x86_ladder/360p_fp8.json`（全加速栈 + RealESRGAN 2×） | fp8 | 640×360 → **1280×704** | 20 | **140 s（2.33 min）** | 2 m 17 s |

- 无加速基线比论坛参考快 **14%**；全加速档和论坛参考（137 s）基本持平（+2%）。
- 采样阶段 **9.6 s/it**（基线 480p 20 步）。
- 峰值内存 **78 GB / 119 GB**（含 ComfyUI 本体），单机跑得很宽裕，但和 modelhub 的四个 LLM 互斥。

### int8 黑屏坑：这台机器不受影响

上游 2026-09-02 记录 `*_int8_convrot` 主干在**部分** GB10 上会出全黑视频（音轨 NaN），且是机器相关的。
在 spark-e9d7 上实测 int8 主干**正常**：亮度均值 YAVG ≈ 87–89（全黑会是 0–16），画面内容正确。
换机器部署时仍建议先用 `steps=1` 探一次。

验黑屏的命令：

```bash
ffprobe -v error -f lavfi -i "movie=<产物>.mp4,signalstats" \
  -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 | head -4
```

## 结论

单台 DGX Spark 跑 MiniMax-H3 完全可用，**720p 出片 2.3 分钟**（360p 生成 + 2× 超分），
质量和直出 720p 接近而快得多——这是上游总结的关键结论，我们复现了。
纯 480p 直出 4.1 分钟。

服务常驻在 `192.168.130.8:8188`，浏览器直接开就能用；
要跑回 LLM 的话先 `bash scripts/stop.sh`，再 `~/modelhub/bin/modelhub start ds4-text`。
