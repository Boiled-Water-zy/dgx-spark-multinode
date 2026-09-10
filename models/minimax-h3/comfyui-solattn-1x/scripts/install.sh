#!/usr/bin/env bash
# MiniMax-H3 视频生成 · 单节点 DGX Spark (GB10) · ComfyUI + Sol-Attn
# 全程国内源：pip=清华 / torch=南大 pytorch 镜像 / 权重=ModelScope
# 幂等，可重复执行。
set -euo pipefail

H3_ROOT="${H3_ROOT:-$HOME/minimax-h3}"
H3_MODELS="${H3_MODELS:-$HOME/models/MiniMax-H3-Comfy}"
COMFY="$H3_ROOT/comfy/ComfyUI"
VENV="$H3_ROOT/comfy/venv"
PY="$VENV/bin/python"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
TORCH_INDEX="${TORCH_INDEX:-https://mirrors.nju.edu.cn/pytorch/whl/cu130}"
COMFY_TAG="${COMFY_TAG:-v0.30.1}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "0/6 系统依赖 (git ffmpeg wget)"
missing=()
for b in git ffmpeg wget; do command -v "$b" >/dev/null || missing+=("$b"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "缺少: ${missing[*]}"
  sudo -n apt-get install -y "${missing[@]}" 2>/dev/null \
    || sudo apt-get install -y "${missing[@]}"
fi

say "1/6 Python venv + PyTorch cu130 (南大镜像)"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$PY" -m pip install -q -U pip -i "$PIP_INDEX"
if ! "$PY" -c 'import torch' 2>/dev/null; then
  "$PY" -m pip install torch torchvision torchaudio \
      --index-url "$TORCH_INDEX" --extra-index-url "$PIP_INDEX"
fi
"$PY" -c 'import torch; print("torch", torch.__version__, "cuda", torch.version.cuda, "avail", torch.cuda.is_available())'

say "2/6 ComfyUI $COMFY_TAG"
# GitHub 在国内经常 SSL timeout，按顺序试：直连 → gh-proxy → ghproxy.net
GH_PREFIXES=(${GH_MIRROR:-} "" "https://gh-proxy.com/" "https://ghproxy.net/")
gh_clone() {  # url dst [extra git args...]
  local url="$1" dst="$2"; shift 2
  [ -d "$dst/.git" ] && return 0
  local p
  for p in "${GH_PREFIXES[@]}"; do
    git clone --depth 1 "$@" "${p}${url}" "$dst" >/dev/null 2>&1 || true
    if [ -d "$dst/.git" ]; then
      git -C "$dst" remote set-url origin "$url"
      return 0
    fi
    rm -rf "$dst"
  done
  echo "!! 克隆失败: $url"
  return 1
}

gh_clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY" --branch "$COMFY_TAG" \
  || gh_clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
git -C "$COMFY" describe --tags 2>/dev/null || git -C "$COMFY" rev-parse --short HEAD

say "3/6 自定义节点 (5 个上游 + Sol-Attn Blackwell + H3 sol-engine ports)"
CN="$COMFY/custom_nodes"; mkdir -p "$CN"
clone_node() {  # name url
  if gh_clone "$2" "$CN/$1"; then echo "  $1 ✓"; else echo "  $1 ✗"; fi
}
clone_node ComfyUI-SolAttn_triton       https://github.com/kijai/ComfyUI-SolAttn_triton.git
clone_node ComfyUI-KJNodes              https://github.com/kijai/ComfyUI-KJNodes.git
clone_node ComfyUI-Spectrum-MiniMax-H3  https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3.git
clone_node ComfyUI-H3-Multishot         https://github.com/jlucasmcrell/ComfyUI-H3-Multishot.git
clone_node ComfyUI-VideoHelperSuite     https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git

HERETIC="$H3_ROOT/keys-heretic-sol-engine"
gh_clone https://github.com/drowzeys/keys-heretic-MiniMax-H3-sol-engine-more-speed-upgrades-upscaler-finish-Single-DGX-Spark.git "$HERETIC" || true
if [ -d "$HERETIC/vendor/ComfyUI_sol-attn_Blackwell" ]; then
  mkdir -p "$CN/ComfyUI_sol-attn_Blackwell"
  cp -r "$HERETIC/vendor/ComfyUI_sol-attn_Blackwell/." "$CN/ComfyUI_sol-attn_Blackwell/"
  echo "  ComfyUI_sol-attn_Blackwell ✓"
fi
if [ -d "$HERETIC/nodes" ]; then
  PORTS="$CN/h3_sol_engine_ports"; mkdir -p "$PORTS"
  for f in h3_fbc_node.py h3_vae_batch.py; do
    [ -f "$HERETIC/nodes/$f" ] || continue
    cp "$HERETIC/nodes/$f" "$PORTS/$f"
    [ -d "$CN/ComfyUI_sol-attn_Blackwell" ] && cp "$HERETIC/nodes/$f" "$CN/ComfyUI_sol-attn_Blackwell/$f"
  done
  cat > "$PORTS/__init__.py" <<'NODEINIT'
from .h3_fbc_node import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS
try:
    from .h3_vae_batch import install as _install_vae_batch
    _install_vae_batch()
except Exception as e:  # 批量 VAE 是可选加速，失败不该拖垮整个节点包
    import logging
    logging.getLogger(__name__).warning("h3_vae_batch install failed: %s", e)
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
NODEINIT
fi

say "4/6 Python 依赖"
"$PY" -m pip install -q -i "$PIP_INDEX" -r "$COMFY/requirements.txt"
"$PY" -m pip install -q -i "$PIP_INDEX" \
  sageattention==1.0.6 sqlalchemy alembic \
  pillow color-matcher matplotlib mss opencv-python-headless imageio-ffmpeg
for req in "$CN"/*/requirements.txt; do
  [ -f "$req" ] && "$PY" -m pip install -q -i "$PIP_INDEX" -r "$req" || true
done

say "5/6 链接权重 $H3_MODELS -> ComfyUI/models"
for sub in diffusion_models text_encoders vae loras upscale_models; do
  mkdir -p "$COMFY/models/$sub" "$H3_MODELS/$sub"
  # 清掉上一轮留下的悬空软链（下载中途的 .incomplete 会变成死链）
  find "$COMFY/models/$sub" -maxdepth 1 -xtype l -delete
  for f in "$H3_MODELS/$sub"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.incomplete|*.tmp|*.part) continue ;; esac
    ln -sfn "$f" "$COMFY/models/$sub/$(basename "$f")"
  done
done
find "$COMFY/models" -maxdepth 2 -type l -printf '  %f\n' | sort

say "6/6 工作流"
WF="$H3_ROOT/workflows"; mkdir -p "$WF"
if [ -d "$H3_ROOT/dgxspark_comfyui_minimax_h3/workflows" ]; then
  cp -r "$H3_ROOT/dgxspark_comfyui_minimax_h3/workflows/." "$WF/"
fi
ls "$WF" | head -20

say "完成。启动: bash scripts/restart.sh"
