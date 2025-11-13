#!/usr/bin/env bash
set -euo pipefail

token="${CIVITAI_TOKEN:-}"
loras="${LORAS_IDS:-}"
ckpts="${LORAS_CHECKPOINTS:-}"

lora_dir="${LORA_DIR:-/home/appuser/models/loras}"
ckpt_dir="${CHECKPOINT_DIR:-/home/appuser/models/checkpoints}"

# Explicit dirs for VAE, diffusion models, CLIP/T5 encoder
vae_dir="${VAE_DIR:-/home/appuser/models/vae}"
diffusion_models_dir="${DIFFUSION_MODELS_DIR:-/home/appuser/models/diffusion_models}"
clip_dir="${CLIP_DIR:-/home/appuser/models/clip}"

mkdir -p "$lora_dir" "$ckpt_dir" "$vae_dir" "$diffusion_models_dir" "$clip_dir"

download_mv() {
  local mv_id="$1"
  local out_dir="$2"
  if [[ -z "$token" ]]; then
    echo "CIVITAI_TOKEN not set; skipping modelVersionId ${mv_id}" >&2
    return 0
  fi
  echo "Downloading Civitai modelVersionId=${mv_id} -> ${out_dir}"
  curl -fL \
    -H "Authorization: Bearer ${token}" \
    "https://civitai.com/api/download/models/${mv_id}" \
    --output /tmp/tmpfile --write-out "%{filename_effective}\n" || {
      echo "Failed mv ${mv_id}" >&2; return 1;
    }
  fname="$(curl -sI -H "Authorization: Bearer ${token}" "https://civitai.com/api/download/models/${mv_id}" | awk -F\" '/filename=/ {print $2; exit}')"
  if [[ -z "$fname" ]]; then fname="${mv_id}.safetensors"; fi
  mv /tmp/tmpfile "${out_dir}/${fname}"
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
declare -A WAN_LORAS=(
  ["wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"]="${WAN_REPO_BASE}/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
  ["wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"]="${WAN_REPO_BASE}/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
  ["wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"]="${WAN_REPO_BASE}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
  ["wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"]="${WAN_REPO_BASE}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
)

for fname in "${!WAN_LORAS[@]}"; do
  url="${WAN_LORAS[$fname]}"
  target="${lora_dir}/${fname}"
  download_file "$url" "$target" || true
done

echo "Downloads complete."
