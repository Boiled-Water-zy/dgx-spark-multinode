# MiniMax-H3 · ComfyUI + Sol-Attn · 单节点

单台 DGX Spark (GB10) 跑 **MiniMax-H3** 视频生成（T2V / I2V / R2V，带音轨），
ComfyUI 工作流形态，权重全部走 **ModelScope 国内 CDN**。

| | |
|---|---|
| 引擎 | ComfyUI v0.30.1 + PyTorch 2.14.0+cu130（venv，非容器） |
| 扩散主干 | `minimax_h3_fl2va_pruned_fp8_scaled`（21 GB，剪枝 + FP8）；备选 `..._int8_convrot`（同尺寸，更快但见下方黑屏坑） |
| 文本编码器 | `qwen3vl_32b_minimax_h3_nvfp4_awq`（15.7 GB，Qwen3-VL-32B 的 NVFP4-AWQ 量化） |
| VAE | `minimax_h3_video_vae_fp16`（5.2 GB）+ `minimax_h3_audio_vae_fp32`（0.6 GB，出音轨用） |
| 加速 | Sol-Attn (Blackwell 预打补丁) + SageAttention 1.0.6 + Spectrum + FBC + 批量 VAE |
| 接口 | HTTP `:8188`（Web UI + `/prompt` 队列 API），**不是 OpenAI 接口** |
| 内存 | 需要 ≥96 GB 统一内存，和本机其它大模型服务**互斥** |
| 磁盘 | 本方案权重 ~67 GB（整仓 477 GB，只取需要的） |

## 部署

```bash
# 0. 先腾内存：一台 GB10 只有 119 GB，跑 H3 前把别的推理服务停掉。
#    130.8 上装了 modelhub 自愈守护，用 docker stop 会被它拉回来，要走它的接口：
~/modelhub/bin/modelhub list
~/modelhub/bin/modelhub stop ds4-text

# 1. 下权重（ModelScope，~67 GB；断点续传，可反复跑）
python3 scripts/download-weights.py phase1     # T2V/I2V 必需
python3 scripts/download-weights.py upscalers  # RealESRGAN 2x/4x，~130 MB（走 hf-mirror）
# phase2 是 Comfy-Org 单独的 Ref2VA checkpoint，随包的 24 个工作流一个都没用到（见下方坑），
# 除非你要自己搭指向它的工作流，否则可以不下：
python3 scripts/download-weights.py phase2     # ~43 GB

# 2. 装环境（pip=清华源，torch=南大 pytorch 镜像，幂等）
bash scripts/install.sh

# 3. 起服务
bash scripts/restart.sh
bash scripts/status.sh

# 4. 自测：提交基线工作流出一段 5 秒视频
python3 scripts/smoke-test.py --host 127.0.0.1 \
    --workflow ~/minimax-h3/workflows/h3-dense-baseline.json
```

浏览器开 `http://<IP>:8188`，把 `~/minimax-h3/workflows/*.json` 拖进去即可。
产物落在 `~/minimax-h3/comfy/ComfyUI/output/video/`。

环境变量：`H3_ROOT`（默认 `~/minimax-h3`）、`H3_MODELS`（默认 `~/models/MiniMax-H3-Comfy`）、
`COMFY_PORT`（默认 8188）。

## 实测（192.168.130.8，GB10）

124 帧 / 5.17s @24fps，带音轨：

| 工作流 | 分辨率 | 步数 | 端到端 |
|---|---|---|---|
| `h3-dense-baseline.json`（无加速） | 864×480 | 20 | **4.11 min** |
| `x86_ladder/360p_fp8.json`（全加速栈 + 2× 超分） | 640×360 → 1280×704 | 20 | **2.33 min** |

峰值内存 78 GB / 119 GB。详见 [`docs/deploy-report.md`](docs/deploy-report.md)。

## 拼长片（单次只有 5.17 秒）

模型单次固定出 124 帧（5.17s @24fps）。要更长的片子，用
[`scripts/make-short-film.py`](scripts/make-short-film.py)：它按分镜逐段生成，
**把上一段的末帧当作下一段的首帧**（I2V 首帧驱动），最后用 ffmpeg 拼起来，
所以镜头是连着走的，人物和场景也能保持一致。

```bash
python3 scripts/make-short-film.py \
    --storyboard storyboards/uas-maritime-strike.json \
    --out ~/film.mp4 --resume
```

分镜就是一个 JSON：`style` 是拼在每段前面的统一风格/人设前缀（保持一致性全靠它），
`shots` 是每段的提示词。已有两个例子：

| 分镜 | 内容 | 段数 | 成片 |
|---|---|---|---|
| [`storyboards/uas-maritime-strike.json`](storyboards/uas-maritime-strike.json) | 无人集群对海作战 | 6 | 31.0s，13 min |
| [`storyboards/lemon-prank-siblings.json`](storyboards/lemon-prank-siblings.json) | 姐弟俩的柠檬恶作剧 | 3 | 15.5s，7.8 min |

`--resume` 会跳过已经出过的段落，所以改某一段时删掉它的产物重跑即可，不用全片重来。

## 工作流

`scripts/install.sh` 会把上游 24 个工作流拷到 `~/minimax-h3/workflows/`。常用的：

| 文件 | 用途 |
|---|---|
| `h3-dense-baseline.json` | T2V 基线，最少依赖，验证装机用这个 |
| `h3-i2v-firstframe-enhanced.json` | 图生视频（首帧驱动）+ 2× 超分 |
| `h3-enhanced-fullstack.json` | 全加速栈完整管线 |
| `h3-multishot-enhanced.json` | 多镜头 |
| `h3-r2v-stockte-enhanced_fp8.json` | 参考图生视频（用本方案的文本编码器，不需要额外权重） |
| `h3-r2v-heretic-enhanced.json` | 同上，但要 HF 上的 "heretic" 文本编码器（32 GB，本方案没下） |
| `x86_ladder/{360,560,720,960}p_fp8.json` | 分辨率阶梯，都指向 fp8 主干 |

带 `_fp8` 后缀的是 FP8 主干版本，其余参数一致。

## 坑

- **int8 主干在部分 GB10 上出全黑视频**（上游 2026-09-02 记录）：`*_int8_convrot` 采样正常、
  不报错，但解码出来整片黑、音轨 NaN，且是**机器相关**的（同样的权重/驱动/内核在另一台同型号
  GB10 上正常），怀疑是 int8 反量化 kernel 踩到硅片 stepping 差异。
  **所以本方案默认用 fp8 主干**，实测所有机器都正常。要验一台机器是否受影响：任意工作流
  `steps=1` 跑一遍，看解出来的帧是不是全黑。
- **上游脚本默认装到 `/root/`、权重从 HuggingFace 拉 91 GB**。本目录的脚本改成装到当前用户家目录、
  权重全部走 ModelScope（`Comfy-Org/MiniMax-H3` 里就有全套 ComfyUI 单文件权重），国内直连 ~17 MB/s。
- **PyTorch cu130 aarch64 轮子**：`download.pytorch.org` 在这边只有 ~130 KB/s，
  换南大镜像 `https://mirrors.nju.edu.cn/pytorch/whl/cu130` 后 4–13 MB/s。
- **ffmpeg 装不上**：机器上的 Ubuntu ESM 源索引是陈的，会 404，先 `sudo apt-get update` 再装。
- **phase2 的 `ref2va` 权重没有工作流用**：R2V（参考图生视频）实际是在 `fl2va` 主干上靠
  `MiniMaxH3ReferenceToVideo` 节点 + 参考图实现的，随包 24 个工作流全部 `UNETLoader` 指向
  `minimax_h3_fl2va_pruned_*`。`ref2va` 是 Comfy-Org 另一条独立 checkpoint，要用得自己搭工作流。
  只想跑通的话 phase2 那 43 GB 可以省掉。
- **带 `-heretic-` 的工作流要额外的文本编码器**（HF `ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-...`，
  25 GB + 7.1 GB，ModelScope 上没有）。用 `-stockte-` 后缀的同款工作流即可，走本方案已有的编码器。
- **随包工作流比自定义节点旧，会被 `/prompt` 打回 400**：`SolAttnPatch` 后来加了
  `dense_blocks`、`int8_pv` 两个必填参数，而工作流 JSON 里没有，报
  `required_input_missing`。`make-short-film.py` 会查 `/object_info` 自动补默认值；
  手动跑的话把这两个参数补进节点 7 即可。
- **`SaveVideo` 的产物挂在 `images` 而不是 `videos` 下**（还带一个 `animated: true`），
  不同版本不一样，从 `/history` 取产物时三个 key 都要看。
- **`modelhub` 会把停掉的容器拉回来**：130.8 上 `modelhub.service` 守着"当前活跃模型"，
  直接 `docker stop` 几分钟后就被自愈重启，内存又被吃掉 101 GB。必须用 `modelhub stop <id>`，
  它会把"停止"记进 `state/active.json`，daemon 才不再干预。
- **生成时间是分钟级不是秒级**，别按 LLM 的 tok/s 直觉去等；首次运行还要额外加载模型 + Triton 编译。

## 参考

- 论坛一键部署帖：<https://forums.developer.nvidia.com/t/dgx-spark-one-click-deploy-for-minimax-h3-12-workflows-sol-attn-acceleration/379894>
- 上游仓库（Gitee 国内镜像）：<https://gitee.com/alexlu0912_admin/dgxspark_comfyui_minimax_h3>
- 实测记录：[`docs/deploy-report.md`](docs/deploy-report.md)
