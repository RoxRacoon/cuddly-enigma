#!/usr/bin/env bash
set -euo pipefail

token="${CIVITAI_TOKEN:-}"
loras="${LORAS_IDS:-}"
ckpts="${LORAS_CHECKPOINTS:-}"

lora_dir="${LORA_DIR:-/home/appuser/models/loras}"
ckpt_dir="${CHECKPOINT_DIR:-/home/appuser/models/checkpoints}"

# New: explicit dirs for VAE, diffusion models, CLIP/T5 encoder
vae_dir="${VAE_DIR:-/home/appuser/models/vae}"
diffusion_models_dir="${DIFFUSION_MODELS_DIR:-/home/appuser/models/diffusion models}"
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
# Extra Lightning LoRAs into $lora_dir
############################################
declare -A EXTRA_LORAS=(
  ["Wan2.2-T2V-A14B-HIGH-4steps-lora-rank64-Seko-V1.1.safetensors"]="https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/high_noise_model.safetensors"
  ["Wan2.2-T2V-A14B-LOW-4steps-lora-rank64-Seko-V1.1.safetensors"]="https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors"

  ["Wan2.2-I2V-A14B-HIGH-4steps-lora-rank64-Seko-V1.safetensors"]="https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1/high_noise_model.safetensors"
  ["Wan2.2-I2V-A14B-LOW-4steps-lora-rank64-Seko-V1.safetensors"]="https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-I2V-A14B-4steps-lora-rank64-Seko-V1/low_noise_model.safetensors"

  ["Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors"
  ["Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors"]="https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan22-Lightning/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors"
)

for fname in "${!EXTRA_LORAS[@]}"; do
  url="${EXTRA_LORAS[$fname]}"
  target="${lora_dir}/${fname}"
  download_file "$url" "$target" || true
done

############################################
# Extra Rapid AIO checkpoint into $ckpt_dir
############################################
extra_ckpt_url="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/wan2.2-rapid-mega-aio-nsfw-v12.safetensors"
extra_ckpt_fname="wan2.2-rapid-mega-aio-nsfw-v12.safetensors"
extra_ckpt_target="${ckpt_dir}/${extra_ckpt_fname}"
download_file "$extra_ckpt_url" "$extra_ckpt_target" || true

############################################
# Wan-AI Wan2.2 base models:
# - VAE -> models/vae
# - T5 encoder -> models/clip
# - high/low diffusion models -> models/diffusion models
############################################

WAN_I2V_REPO="https://huggingface.co/Wan-AI/Wan2.2-I2V-A14B/resolve/main"
WAN_T2V_REPO="https://huggingface.co/Wan-AI/Wan2.2-T2V-A14B/resolve/main"

WAN_I2V_NAME="Wan2.2-I2V-A14B"
WAN_T2V_NAME="Wan2.2-T2V-A14B"

# Directories laid out inside your requested base folders
WAN_I2V_VAE_DIR="${vae_dir}/${WAN_I2V_NAME}"
WAN_T2V_VAE_DIR="${vae_dir}/${WAN_T2V_NAME}"

WAN_I2V_CLIP_DIR="${clip_dir}/${WAN_I2V_NAME}"
WAN_T2V_CLIP_DIR="${clip_dir}/${WAN_T2V_NAME}"

WAN_I2V_DIFF_DIR="${diffusion_models_dir}/${WAN_I2V_NAME}"
WAN_T2V_DIFF_DIR="${diffusion_models_dir}/${WAN_T2V_NAME}"

mkdir -p "$WAN_I2V_VAE_DIR" "$WAN_T2V_VAE_DIR" \
         "$WAN_I2V_CLIP_DIR" "$WAN_T2V_CLIP_DIR" \
         "$WAN_I2V_DIFF_DIR"/{high_noise_model,low_noise_model} \
         "$WAN_T2V_DIFF_DIR"/{high_noise_model,low_noise_model}

# Filenames
WAN_VAE_FILE="Wan2.1_VAE.pth"
WAN_T5_FILE="models_t5_umt5-xxl-enc-bf16.pth"

# I2V: VAE + T5
download_file "${WAN_I2V_REPO}/${WAN_VAE_FILE}" \
              "${WAN_I2V_VAE_DIR}/${WAN_VAE_FILE}" || true
download_file "${WAN_I2V_REPO}/${WAN_T5_FILE}" \
              "${WAN_I2V_CLIP_DIR}/${WAN_T5_FILE}" || true

# T2V: VAE + T5
download_file "${WAN_T2V_REPO}/${WAN_VAE_FILE}" \
              "${WAN_T2V_VAE_DIR}/${WAN_VAE_FILE}" || true
download_file "${WAN_T2V_REPO}/${WAN_T5_FILE}" \
              "${WAN_T2V_CLIP_DIR}/${WAN_T5_FILE}" || true

# High/low noise diffusion shards + index for both repos
WAN_DIFF_FILES=(
  "config.json"
  "diffusion_pytorch_model-00001-of-00006.safetensors"
  "diffusion_pytorch_model-00002-of-00006.safetensors"
  "diffusion_pytorch_model-00003-of-00006.safetensors"
  "diffusion_pytorch_model-00004-of-00006.safetensors"
  "diffusion_pytorch_model-00005-of-00006.safetensors"
  "diffusion_pytorch_model-00006-of-00006.safetensors"
  "diffusion_pytorch_model.safetensors.index.json"
)

for fname in "${WAN_DIFF_FILES[@]}"; do
  # I2V high / low -> models/diffusion models/Wan2.2-I2V-A14B/...
  download_file "${WAN_I2V_REPO}/high_noise_model/${fname}" \
                "${WAN_I2V_DIFF_DIR}/high_noise_model/${fname}" || true
  download_file "${WAN_I2V_REPO}/low_noise_model/${fname}" \
                "${WAN_I2V_DIFF_DIR}/low_noise_model/${fname}" || true

  # T2V high / low -> models/diffusion models/Wan2.2-T2V-A14B/...
  download_file "${WAN_T2V_REPO}/high_noise_model/${fname}" \
                "${WAN_T2V_DIFF_DIR}/high_noise_model/${fname}" || true
  download_file "${WAN_T2V_REPO}/low_noise_model/${fname}" \
                "${WAN_T2V_DIFF_DIR}/low_noise_model/${fname}" || true
done

echo "Downloads complete."
