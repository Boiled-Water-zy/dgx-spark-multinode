# MiniMax-H3 · 视频生成 · 单节点 DGX Spark

**MiniMax-H3 不是 LLM，是 33B 全模态视频生成模型**（文生视频 / 图生视频 / 参考图生视频，带音轨），
2026-08-03 开源。跑法和本仓库其它模型完全不同：不走 vLLM/SGLang 的 OpenAI 接口，
走 **ComfyUI 工作流**（HTTP :8188 + `/prompt` 队列 API）。

> 方案出处：[NVIDIA DGX Spark 论坛版块](https://forums.developer.nvidia.com/c/accelerated-computing/dgx-spark-gb10/719)
> · [一键部署帖（12 工作流 + Sol-Attn 加速）](https://forums.developer.nvidia.com/t/dgx-spark-one-click-deploy-for-minimax-h3-12-workflows-sol-attn-acceleration/379894)
> · [单机耗时讨论帖](https://forums.developer.nvidia.com/t/it-takes-6-minutes-for-minimax-h3-to-generate-a-5-second-480p-video-on-dgx-spark-how-long-does-it-take-for-yours/379139)
> · 上游脚本仓库（Gitee，国内可直连）：<https://gitee.com/alexlu0912_admin/dgxspark_comfyui_minimax_h3>

| 方案 | 目录 | 引擎 | 节点 | 权重 |
|---|---|---|---|---|
| ComfyUI + Sol-Attn 加速 | [`comfyui-solattn-1x/`](comfyui-solattn-1x) | ComfyUI v0.30.1 + PyTorch cu130 | 1 | pruned fp8 / int8-convrot + NVFP4-AWQ 文本编码器 |

## 为什么单机跑得动

原始 BF16 权重 66 GB × 2（FL2VA + Ref2VA）+ 51 GB 文本编码器，单台 119 GB 统一内存装不下。
社区把扩散主干**剪枝 + INT8/FP8 量化**压到 21 GB，文本编码器（Qwen3-VL-32B）压到
**NVFP4-AWQ 15.7 GB**，一台 GB10 就够，且 ComfyUI 按阶段加载/卸载，峰值远低于总和。

## 权重来源（全部走 ModelScope 国内 CDN）

[`Comfy-Org/MiniMax-H3`](https://modelscope.cn/models/Comfy-Org/MiniMax-H3) 里已经有全部
ComfyUI 单文件版权重（整仓 477 GB，我们只取需要的 ~67 GB）。
上游脚本默认从 HuggingFace 拉 91 GB，本仓库改成 ModelScope 直连，见
[`comfyui-solattn-1x/scripts/download-weights.py`](comfyui-solattn-1x/scripts/download-weights.py)。
