#!/usr/bin/env bash
set -euo pipefail

# Activate venv
source /home/appuser/venv/bin/activate

# Download models if requested
/home/appuser/downloader.sh || true

# (Optional) Wire SageAttention as SDPA drop-in for PyTorch
if [[ "${USE_SAGEATTN:-1}" == "1" ]]; then
python - <<'PY'
import torch, torch.nn.functional as F
try:
    from sageattention import sageattn
    F.scaled_dot_product_attention = sageattn
    print("[SageAttention] Patched scaled_dot_product_attention OK")
except Exception as e:
    print("[SageAttention] Patch skipped:", e)
PY
fi

# Launch services:
# 1) CopyParty file manager/uploader on :3923
copyparty --port 3923 ${COPY_PARTY_ARGS:-} "${COPY_PARTY_ROOT:-/home/appuser}" > /home/appuser/copyparty.log 2>&1 &

# 2) ttyd web terminal on :7681
ttyd -p 7681 /bin/bash > /home/appuser/ttyd.log 2>&1 &

# 3) ComfyUI on :8188 (no browser)
cd /home/appuser/ComfyUI
mkdir -p /home/appuser/ComfyUI/models/checkpoints /home/appuser/ComfyUI/models/loras
ln -sf "${CHECKPOINT_DIR:-/home/appuser/models/checkpoints}" /home/appuser/ComfyUI/models/checkpoints_ext
ln -sf "${LORA_DIR:-/home/appuser/models/loras}" /home/appuser/ComfyUI/models/loras_ext

python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_ARGS:-}
