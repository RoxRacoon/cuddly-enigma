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
  TORCH_CUDA_CHANNEL="${PYTORCH_CUDA_CHANNEL:-cu128}"
  echo "[Init] PyTorch not detected in venv. Installing ${TORCH_CUDA_CHANNEL} wheels..."
  pip install --index-url "https://download.pytorch.org/whl/${TORCH_CUDA_CHANNEL}" \
      torch torchvision torchaudio --extra-index-url https://pypi.org/simple
fi

CUDA_READY=0
CUDA_WAIT_ATTEMPTS=${CUDA_WAIT_ATTEMPTS:-30}
CUDA_WAIT_DELAY=${CUDA_WAIT_DELAY:-2}
if [[ "${SKIP_CUDA_WAIT:-0}" == "1" ]]; then
  if python - <<'PY' >/dev/null 2>&1; then
import torch
torch.cuda.current_device()
PY
    CUDA_READY=1
  fi
else
  for ((attempt = 1; attempt <= CUDA_WAIT_ATTEMPTS; attempt++)); do
    if python - <<'PY' >/dev/null 2>&1; then
import torch
if torch.cuda.is_available():
    torch.cuda.current_device()
    raise SystemExit(0)
raise SystemExit(1)
PY
      CUDA_READY=1
      break
    fi
    echo "[Init] CUDA not ready yet (${attempt}/${CUDA_WAIT_ATTEMPTS}); retrying in ${CUDA_WAIT_DELAY}s..."
    sleep "${CUDA_WAIT_DELAY}"
  done
fi

if [[ "${CUDA_READY}" == "1" ]]; then
  echo "[Init] CUDA detected and ready."
else
  echo "[Init] WARNING: CUDA could not be initialized. Continuing without it; ComfyUI may run on CPU or fail if it requires a GPU."
fi

# -----------------------------------------------------------------------------
# 1️⃣ Install SageAttention at runtime (prefers SageAttention3, falls back to 2.x)
# -----------------------------------------------------------------------------
if [[ "${USE_SAGEATTN:-1}" == "1" ]]; then
  echo "[SageAttention] Attempting runtime install..."
  if [[ "${CUDA_READY}" == "1" ]]; then
    if [[ -z "${CUDA_HOME:-}" ]]; then
      CUDA_HOME_FROM_TORCH=$(python - <<'PY'
import os
from torch.utils.cpp_extension import CUDA_HOME

if CUDA_HOME:
    print(os.path.realpath(CUDA_HOME))
PY
)
      if [[ -n "${CUDA_HOME_FROM_TORCH}" ]]; then
        export CUDA_HOME="${CUDA_HOME_FROM_TORCH}"
        export CUDA_PATH="${CUDA_PATH:-${CUDA_HOME_FROM_TORCH}}"
        echo "[SageAttention] Using CUDA toolkit from ${CUDA_HOME_FROM_TORCH}"
      else
        echo "[SageAttention] WARNING: Unable to infer CUDA toolkit path; build may fail."
      fi
    fi
    attempt_sageattn_install() {
      local spec="$1"
      local desc="$2"
      local impl="${3:-}"
      echo "[SageAttention] Installing ${desc}..."
      if PIP_NO_BUILD_ISOLATION=1 python -m pip install --no-build-isolation --no-cache-dir "$spec"; then
        echo "[SageAttention] Installed ${desc}."
        if [[ -n "${impl}" ]]; then
          export SAGEATTN_IMPL="${impl}"
        fi
        return 0
      fi
      echo "[SageAttention] ${desc} installation failed."
      return 1
    }
    if [[ -n "${SAGEATTN_IMPL:-}" ]]; then
      unset SAGEATTN_IMPL
    fi
    SAGEATTN_FLAVOR="${SAGEATTN_FLAVOR:-3}"
    SAGEATTN_FALLBACK_TO_V2="${SAGEATTN_FALLBACK_TO_V2:-1}"
    SAGEATTN_CUSTOM_SPEC="${SAGEATTN_PIP_SPEC:-}"
    SAGEATTN_INSTALL_ORDER=()
    if [[ -n "${SAGEATTN_CUSTOM_SPEC}" ]]; then
      SAGEATTN_INSTALL_ORDER+=("custom")
    else
      case "${SAGEATTN_FLAVOR}" in
        3)
          SAGEATTN_INSTALL_ORDER+=("3")
          if [[ "${SAGEATTN_FALLBACK_TO_V2}" == "1" ]]; then
            SAGEATTN_INSTALL_ORDER+=("2")
          fi
          ;;
        2)
          SAGEATTN_INSTALL_ORDER+=("2")
          ;;
        *)
          SAGEATTN_CUSTOM_SPEC="${SAGEATTN_FLAVOR}"
          SAGEATTN_INSTALL_ORDER+=("custom")
          ;;
      esac
    fi
    SAGEATTN_INSTALL_SUCCEEDED=0
    for target in "${SAGEATTN_INSTALL_ORDER[@]}"; do
      case "${target}" in
        3)
          SAGEATTN_GIT_URL="${SAGEATTN_GIT_URL:-https://github.com/thu-ml/SageAttention.git}"
          SAGEATTN_GIT_REF="${SAGEATTN_GIT_REF:-main}"
          SAGEATTN_GIT_SUBDIR="${SAGEATTN_GIT_SUBDIR:-sageattention3_blackwell}"
          SAGEATTN_SPEC="sageattn3 @ git+${SAGEATTN_GIT_URL}@${SAGEATTN_GIT_REF}#subdirectory=${SAGEATTN_GIT_SUBDIR}"
          if attempt_sageattn_install "${SAGEATTN_SPEC}" "SageAttention3 (${SAGEATTN_GIT_REF})" "sageattn3"; then
            SAGEATTN_INSTALL_SUCCEEDED=1
            break
          fi
          ;;
        2)
          if attempt_sageattn_install "sageattention>=2.2,<3" "SageAttention2.x (PyPI)" "sageattention"; then
            SAGEATTN_INSTALL_SUCCEEDED=1
            break
          fi
          ;;
        custom)
          if attempt_sageattn_install "${SAGEATTN_CUSTOM_SPEC}" "custom SageAttention spec" ""; then
            SAGEATTN_INSTALL_SUCCEEDED=1
            break
          fi
          ;;
      esac
    done
    if [[ "${SAGEATTN_INSTALL_SUCCEEDED}" != "1" ]]; then
      echo "[SageAttention] Install failed (check CUDA toolkit / dependencies). Continuing without it."
    fi
  else
    echo "[SageAttention] CUDA not detected; skipping install."
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
import os
import torch.nn.functional as F

preferred = os.environ.get("SAGEATTN_IMPL")
order = []
if preferred == "sageattn3":
    order.append("sageattn3")
elif preferred == "sageattention":
    order.append("sageattention")
for candidate in ("sageattn3", "sageattention"):
    if candidate not in order:
        order.append(candidate)

last_exc = None
patched = False
for candidate in order:
    try:
        if candidate == "sageattn3":
            from sageattn3 import sageattn3_blackwell as _sageattn
            label = "SageAttention3"
        else:
            from sageattention import sageattn as _sageattn
            label = "SageAttention"
    except Exception as exc:  # pragma: no cover - best-effort logging
        last_exc = exc
        continue
    F.scaled_dot_product_attention = _sageattn
    print(f"[SageAttention] Successfully patched torch.nn.functional.scaled_dot_product_attention with {label}")
    patched = True
    break

if not patched:
    detail = f" {last_exc}" if last_exc else ""
    print(f"[SageAttention] Not available.{detail}")
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
