#!/usr/bin/env bash
set -euo pipefail

# Activate Python virtual environment
source /home/appuser/venv/bin/activate

# Ensure pip is new enough to understand --no-build-isolation reliably. Older
# releases silently ignored the flag in some edge cases, which would drop us
# back into an isolated build env without torch and recreate the failure seen on
# RunPod. Upgrade lazily (only when necessary) to avoid redundant downloads.
if ! python - <<'PY' >/dev/null; then
import pip
from itertools import zip_longest

def parse(version: str):
    parts = []
    for chunk in version.split('.'):
        if chunk.isdigit():
            parts.append(int(chunk))
        else:
            break
    return parts

target = parse('23.1')
current = parse(pip.__version__)
for c, t in zip_longest(current, target, fillvalue=0):
    if c < t:
        raise SystemExit(1)
    if c > t:
        raise SystemExit(0)
raise SystemExit(0)
PY
  python -m pip install --upgrade 'pip>=23.1' 'setuptools>=68' 'wheel'
fi

echo "[Init] Starting container setup..."

# Ensure PyTorch is present before doing anything that depends on it
if ! python -c "import torch" >/dev/null 2>&1; then
  echo "[Init] PyTorch not detected in venv. Installing CUDA 12.8 wheels..."
  pip install --index-url https://download.pytorch.org/whl/cu128 \
      torch torchvision torchaudio --extra-index-url https://pypi.org/simple
fi

# -----------------------------------------------------------------------------
# 1️⃣ Install SageAttention at runtime (GPU available on RunPod)
# -----------------------------------------------------------------------------
if [[ "${USE_SAGEATTN:-1}" == "1" ]]; then
  echo "[SageAttention] Attempting runtime install..."
  # SageAttention's build process imports torch in setup.py, which fails under pip's
  # default isolated build environment because torch isn't present there. Tell pip to
  # reuse the current environment (where torch has already been installed) so the
  # build can succeed.
  # Explicitly disable pip's isolated build env so sageattention's setup.py can
  # import torch that we just installed above. The environment variable alone
  # is not always honored on some older pip builds, so pass the CLI flag too.
  if PIP_NO_BUILD_ISOLATION=1 python -m pip install --no-build-isolation --no-cache-dir "sageattention==2.2.0"; then
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

ln -sf "${CHECKPOINT_DIR:-/home/appuser/ComfyUI/models/checkpoints}" /home/appuser/ComfyUI/models/checkpoints_ext
ln -sf "${LORA_DIR:-/home/appuser/ComfyUI/models/loras}" /home/appuser/ComfyUI/models/loras_ext

# -----------------------------------------------------------------------------
# 7️⃣ Launch ComfyUI server
# -----------------------------------------------------------------------------
echo "[ComfyUI] Starting ComfyUI on port 8188..."
python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_ARGS:-}

# -----------------------------------------------------------------------------
# 8️⃣ Keep container alive
# -----------------------------------------------------------------------------
wait
