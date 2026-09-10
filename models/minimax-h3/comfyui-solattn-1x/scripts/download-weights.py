#!/usr/bin/env python3
"""下载 MiniMax-H3 的 ComfyUI 权重到 ~/models/MiniMax-H3-Comfy。

扩散主干 / 文本编码器 / VAE / LoRA 全部走 ModelScope 国内 CDN（Comfy-Org/MiniMax-H3）；
只有两个超分模型 ModelScope 上没有，走 hf-mirror.com。

  python3 download-weights.py phase1      # T2V/I2V 必需 ~67 GB
  python3 download-weights.py phase2      # R2V 追加 ~43 GB
  python3 download-weights.py upscalers   # 2x/4x 超分 ~130 MB
"""
import os, subprocess, sys, time
from modelscope.hub.snapshot_download import snapshot_download

LOCAL = os.path.expanduser("~/models/MiniMax-H3-Comfy")

# phase1: T2V / I2V essentials ; phase2: R2V (reference-to-video)
PHASES = {
    "phase1": [
        "diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors",
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors",
        "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
        "vae/minimax_h3_video_vae_fp16.safetensors",
        "vae/minimax_h3_audio_vae_fp32.safetensors",
        "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors",
        "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
    ],
    "phase2": [
        "diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors",
        "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
        "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors",
    ],
}

HF_MIRROR = os.environ.get("HF_ENDPOINT", "https://hf-mirror.com")
HF_REPO = "drowzeys/keys-heretic-MiniMax-H3-sol-engine-more-DGX-Spark-weights"
UPSCALERS = ["RealESRGAN_x2plus.pth", "RealESRGAN_x4plus.pth"]


def get_upscalers():
    """超分模型 ModelScope 没有，从 hf-mirror 拉（各 ~65 MB）。"""
    dst_dir = os.path.join(LOCAL, "upscale_models")
    os.makedirs(dst_dir, exist_ok=True)
    for name in UPSCALERS:
        dst = os.path.join(dst_dir, name)
        if os.path.exists(dst):
            print(f"[skip] {name}", flush=True)
            continue
        url = f"{HF_MIRROR}/{HF_REPO}/resolve/main/upscale_models/{name}"
        print(f"[get ] {name}", flush=True)
        subprocess.run(["wget", "-q", "--show-progress", "--tries=3", "--timeout=60",
                        "-O", dst, url], check=True)
        print(f"[done] {name}  {os.path.getsize(dst)/1e6:.0f} MB", flush=True)


phase = sys.argv[1] if len(sys.argv) > 1 else "phase1"
if phase == "upscalers":
    os.makedirs(LOCAL, exist_ok=True)
    get_upscalers()
    print("=== upscalers complete ===")
    sys.exit(0)
files = PHASES[phase]
os.makedirs(LOCAL, exist_ok=True)
for f in files:
    dst = os.path.join(LOCAL, f)
    if os.path.exists(dst):
        print(f"[skip] {f} ({os.path.getsize(dst)/1e9:.1f} GB)", flush=True)
        continue
    print(f"[get ] {f}", flush=True)
    t0 = time.time()
    for attempt in range(1, 6):
        try:
            snapshot_download("Comfy-Org/MiniMax-H3", local_dir=LOCAL, allow_patterns=[f])
            break
        except Exception as e:
            print(f"  retry {attempt}/5 after error: {e}", flush=True)
            time.sleep(10)
    else:
        print(f"[FAIL] {f}", flush=True); sys.exit(1)
    sz = os.path.getsize(dst)/1e9
    dt = time.time()-t0
    print(f"[done] {f}  {sz:.1f} GB in {dt/60:.1f} min ({sz*1000/max(dt,1):.1f} MB/s)", flush=True)
print(f"=== {phase} complete ===", flush=True)
