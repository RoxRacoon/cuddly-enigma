#!/usr/bin/env bash
set -euo pipefail

# Activate Python virtual environment
source /home/appuser/venv/bin/activate

echo "[Init] Starting container setup..."

# -----------------------------------------------------------------------------
# 1️⃣ Install SageAttention at runtime (GPU available on RunPod)
# -----------------------------------------------------------------------------
if [[ "${USE_SAGEATTN:-1}" == "1" ]]; then
  echo "[SageAttention] Attempting runtime install..."
  if pip install --no-cache-dir "sageattention==2.2.0"; then
    echo "[SageAttention] Installed successfully."
  else
    echo "[SageAttention] Install failed (likely no CUDA). Continuing without it."
  fi
fi

# -----------------------------------------------------------------------------
# 2️⃣ Run downloader script (optional civitai model fetcher)
# -----------------------------------------------------------------------------
if [[ -x "/home/appuser/downloader.sh" ]]; then
  echo "[Downloader] Running downloader.sh..."
  /home/appuser/downloader.sh || echo "[Downloader] Skipped or failed."
fi

# -----------------------------------------------------------------------------
# 3️⃣ Patch PyTorch SDPA to use SageAttention if available
# -----------------------------------------------------------------------------
if [[ "${USE_SAGEATTN:-1}" == "1" ]]; then
python - <<'PY'
import torch, torch.nn.functional as F
try:
    from sageattention import sageattn
    F.scaled_dot_product_attention = sageattn
    print("[SageAttention] Successfully patched torch.nn.functional.scaled_dot_product_attention")
except Exception as e:
    print("[SageAttention] Not available:", e)
PY
fi

# -----------------------------------------------------------------------------
# 4️⃣ Launch CopyParty (web-based file manager)
# -----------------------------------------------------------------------------
echo "[CopyParty] Starting file manager on port 3923..."
copyparty --port 3923 ${COPY_PARTY_ARGS:-} "${COPY_PARTY_ROOT:-/home/appuser}" \
    > /home/appuser/copyparty.log 2>&1 &

# -----------------------------------------------------------------------------
# 5️⃣ Launch ttyd (web-based terminal)
# -----------------------------------------------------------------------------
echo "[ttyd] Starting terminal on port 7681..."
ttyd -p 7681 /bin/bash > /home/appuser/ttyd.log 2>&1 &

# -----------------------------------------------------------------------------
# 6️⃣ Prepare ComfyUI model paths
# -----------------------------------------------------------------------------
echo "[ComfyUI] Preparing model directories..."
cd /home/appuser/ComfyUI

# Ensure default model directories exist (both for ComfyUI and shared storage)
mkdir -p /home/appuser/ComfyUI/models/checkpoints
mkdir -p /home/appuser/ComfyUI/models/loras
mkdir -p /home/appuser/models/checkpoints
mkdir -p /home/appuser/models/loras
mkdir -p /home/appuser/models/vae
mkdir -p /home/appuser/models/diffusion_model
mkdir -p /home/appuser/models/clip

ln -sf "${CHECKPOINT_DIR:-/home/appuser/models/checkpoints}" /home/appuser/ComfyUI/models/checkpoints_ext
ln -sf "${LORA_DIR:-/home/appuser/models/loras}" /home/appuser/ComfyUI/models/loras_ext
ln -sf "${VAE_DIR:-/home/appuser/models/vae}" /home/appuser/ComfyUI/models/vae_ext
ln -sf "${DIFFUSION_MODELS_DIR:-/home/appuser/models/diffusion_model}" /home/appuser/ComfyUI/models/diffusion_models_ext
ln -sf "${CLIP_DIR:-/home/appuser/models/clip}" /home/appuser/ComfyUI/models/clip_ext

# -----------------------------------------------------------------------------
# 7️⃣ Launch ComfyUI server
# -----------------------------------------------------------------------------
echo "[ComfyUI] Starting ComfyUI on port 8188..."
python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_ARGS:-}

# -----------------------------------------------------------------------------
# 8️⃣ Keep container alive
# -----------------------------------------------------------------------------
wait
