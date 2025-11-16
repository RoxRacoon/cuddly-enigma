#!/usr/bin/env bash
set -euo pipefail

token="${CIVITAI_TOKEN:-}"
loras="${LORAS_IDS:-}"
ckpts="${LORAS_CHECKPOINTS:-}"

LORA_DEFAULT="/home/appuser/ComfyUI/models/loras"
CHECKPOINT_DEFAULT="/home/appuser/ComfyUI/models/checkpoints"

lora_dir="${LORA_DIR:-${LORA_DEFAULT}}"
ckpt_dir="${CHECKPOINT_DIR:-${CHECKPOINT_DEFAULT}}"

# Explicit dirs for VAE, diffusion models, CLIP/T5 encoder
vae_dir="${VAE_DIR:-/home/appuser/ComfyUI/models/vae}"
diffusion_models_dir="${DIFFUSION_MODELS_DIR:-/home/appuser/ComfyUI/models/diffusion_models}"
clip_dir="${CLIP_DIR:-/home/appuser/ComfyUI/models/clip}"

mkdir -p "$lora_dir" "$ckpt_dir" "$vae_dir" "$diffusion_models_dir" "$clip_dir"

download_mv() {
  local mv_id="$1"
  local out_dir="$2"
  if [[ -z "$token" ]]; then
    echo "CIVITAI_TOKEN not set; skipping modelVersionId ${mv_id}" >&2
    return 0
  fi

  mkdir -p "$out_dir"

  # Try to discover the filename up front via a HEAD request so we can skip
  # downloading the same LoRA multiple times (Civitai returns a unique
  # Content-Disposition header for each modelVersionId).
  local head_tmp filename="" dest=""
  head_tmp="$(mktemp)"
  if curl -fsSLI \
      -H "Authorization: Bearer ${token}" \
      "https://civitai.com/api/download/models/${mv_id}" \
      -o /dev/null -D "$head_tmp"; then
    filename="$(python - <<'PY' "$head_tmp"
import re
import sys
from email.parser import Parser
from urllib.parse import unquote

path = sys.argv[1]
with open(path, 'rb') as fh:
    raw = fh.read().decode('utf-8', 'ignore')

sections = [s for s in raw.split('\r\n\r\n') if s.strip()]
headers = Parser().parsestr(sections[-1]) if sections else None
filename = ''
if headers:
    cd = headers.get('Content-Disposition', '')
    if cd:
        match_star = re.search(r'filename\*=([^;]+)', cd, re.IGNORECASE)
        if match_star:
            value = match_star.group(1).strip().strip('"')
            if value.lower().startswith("utf-8''"):
                value = unquote(value[7:])
            filename = value
        if not filename:
            match = re.search(r'filename="?([^";]+)"?', cd, re.IGNORECASE)
            if match:
                filename = match.group(1).strip()
if filename:
    print(filename)
PY
)"
    if [[ -n "$filename" ]]; then
      dest="${out_dir}/${filename}"
      if [[ -f "$dest" ]]; then
        echo "Civitai modelVersionId=${mv_id} already downloaded (${filename}); skipping."
        rm -f "$head_tmp"
        return 0
      fi
    fi
  fi
  rm -f "$head_tmp"

  echo "Downloading Civitai modelVersionId=${mv_id} -> ${out_dir}"
  if ! (
    cd "$out_dir" && \
    curl -fL \
      -H "Authorization: Bearer ${token}" \
      --remote-header-name --remote-name \
      "https://civitai.com/api/download/models/${mv_id}"
  ); then
    echo "Failed mv ${mv_id}" >&2
    return 1
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  if [[ -f "$dest" ]]; then
    echo "File already exists, skipping: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  echo "Downloading $url -> $dest"
  if ! curl -fL "$url" -o "$dest"; then
    wget -O "$dest" "$url" || {
      echo "Failed to download $url" >&2
      rm -f "$dest"
      return 1
    }
  fi
}

# Wan LoRAs are provided by the Comfy-Org repackaged release and should
# always be fetched to ensure users have the curated weights. They bypass the
# generic download helper so they are unaffected by user-provided environment
# overrides.
download_wan_lora() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.tmp"

  mkdir -p "$(dirname "$dest")"
  rm -f "$tmp"

  echo "Force-downloading Wan2.2 LoRA $url -> $dest"
  if curl -fL "$url" -o "$tmp"; then
    mv "$tmp" "$dest"
  else
    echo "Failed to download Wan2.2 LoRA from $url" >&2
    rm -f "$tmp"
    return 1
  fi
}

################################
# Civitai LoRAs (by mv_id)
################################
IFS=',' read -ra LARR <<< "$loras"
for mv in "${LARR[@]}"; do
  mv="$(echo "$mv" | xargs)"
  [[ -z "$mv" ]] && continue
  download_mv "$mv" "$lora_dir" || true
done

################################
# Checkpoints (mv_id or URL)
################################
IFS=',' read -ra CARR <<< "$ckpts"
for item in "${CARR[@]}"; do
  item="$(echo "$item" | xargs)"
  [[ -z "$item" ]] && continue
  if [[ "$item" =~ ^https?:// ]]; then
    echo "Downloading URL ${item}"
    cd "$ckpt_dir"
    if [[ -n "$token" ]]; then
      curl -fL -H "Authorization: Bearer ${token}" "$item" --remote-header-name --remote-name || \
      wget --header="Authorization: Bearer ${token}" --content-disposition "$item" || true
    else
      wget --content-disposition "$item" || curl -fLO "$item" || true
    fi
  else
    download_mv "$item" "$ckpt_dir" || true
  fi
done

############################################
# Wan 2.2 – Comfy-Org repackaged assets
#   Source: Comfy-Org/Wan_2.2_ComfyUI_Repackaged
############################################

WAN_REPO_BASE="https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files"

# VAE
download_file \
  "${WAN_REPO_BASE}/vae/wan_2.1_vae.safetensors" \
  "${vae_dir}/wan_2.1_vae.safetensors" || true

# Text encoder (T5/UMT5)
download_file \
  "${WAN_REPO_BASE}/text_encoders/umt5_xxl_fp16.safetensors" \
  "${clip_dir}/umt5_xxl_fp16.safetensors" || true

# Diffusion models (fp8 scaled)
declare -A WAN_DIFFUSORS=(
  ["wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"]="${WAN_REPO_BASE}/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"
  ["wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"]="${WAN_REPO_BASE}/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
  ["wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"]="${WAN_REPO_BASE}/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
  ["wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"]="${WAN_REPO_BASE}/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

for fname in "${!WAN_DIFFUSORS[@]}"; do
  url="${WAN_DIFFUSORS[$fname]}"
  target="${diffusion_models_dir}/${fname}"
  download_file "$url" "$target" || true
done

# Wan 2.2 Lightning LoRAs (Comfy-Org versions)
WAN_LORAS=(
  "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
  "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
  "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
)

for fname in "${WAN_LORAS[@]}"; do
  url="${WAN_REPO_BASE}/loras/${fname}"
  target="${lora_dir}/${fname}"
  download_wan_lora "$url" "$target" || true
done

echo "Downloads complete."
