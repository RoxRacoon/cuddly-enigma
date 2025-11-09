#!/usr/bin/env bash
set -euo pipefail

token="${CIVITAI_TOKEN:-}"
loras="${LORAS_IDS:-}"
ckpts="${LORAS_CHECKPOINTS:-}"
lora_dir="${LORA_DIR:-/home/appuser/models/loras}"
ckpt_dir="${CHECKPOINT_DIR:-/home/appuser/models/checkpoints}"

mkdir -p "$lora_dir" "$ckpt_dir"

download_mv() {
  local mv_id="$1"
  local out_dir="$2"
  if [[ -z "$token" ]]; then
    echo "CIVITAI_TOKEN not set; skipping modelVersionId ${mv_id}" >&2
    return 0
  fi
  # modelVersion endpoint form: /api/download/models/{modelVersionId}
  # --content-disposition preserves proper filenames
  echo "Downloading Civitai modelVersionId=${mv_id} -> ${out_dir}"
  curl -fL \
    -H "Authorization: Bearer ${token}" \
    "https://civitai.com/api/download/models/${mv_id}" \
    --output /tmp/tmpfile --write-out "%{filename_effective}\n" || {
      echo "Failed mv ${mv_id}" >&2; return 1;
    }
  # Use server filename if present; otherwise move tmpfile with mv_id name
  fname="$(curl -sI -H "Authorization: Bearer ${token}" "https://civitai.com/api/download/models/${mv_id}" | awk -F\" '/filename=/ {print $2; exit}')"
  if [[ -z "$fname" ]]; then fname="${mv_id}.safetensors"; fi
  mv /tmp/tmpfile "${out_dir}/${fname}"
}

# LoRAs (modelVersionIds)
IFS=',' read -ra LARR <<< "$loras"
for mv in "${LARR[@]}"; do
  mv="$(echo "$mv" | xargs)"
  [[ -z "$mv" ]] && continue
  download_mv "$mv" "$lora_dir" || true
done

# Checkpoints (accept either modelVersionIds or full URLs)
IFS=',' read -ra CARR <<< "$ckpts"
for item in "${CARR[@]}"; do
  item="$(echo "$item" | xargs)"
  [[ -z "$item" ]] && continue
  if [[ "$item" =~ ^https?:// ]]; then
    echo "Downloading URL ${item}"
    cd "$ckpt_dir"
    # Try with token first (works for login-required links if they’re direct API URLs)
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
# Extra HuggingFace LoRAs into $lora_dir  #
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
  # Skip if already exists
  if [[ -f "$target" ]]; then
    echo "LoRA already exists, skipping: $target"
    continue
  fi
  echo "Downloading extra LoRA ${fname} from ${url}"
  if ! curl -fL "$url" -o "$target"; then
    wget -O "$target" "$url" || true
  fi
done

############################################
# Extra HuggingFace checkpoint into $ckpt_dir
############################################

extra_ckpt_url="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/wan2.2-rapid-mega-aio-nsfw-v12.safetensors"
extra_ckpt_fname="wan2.2-rapid-mega-aio-nsfw-v12.safetensors"
extra_ckpt_target="${ckpt_dir}/${extra_ckpt_fname}"

if [[ -f "$extra_ckpt_target" ]]; then
  echo "Checkpoint already exists, skipping: $extra_ckpt_target"
else
  echo "Downloading extra checkpoint ${extra_ckpt_fname} from ${extra_ckpt_url}"
  if ! curl -fL "$extra_ckpt_url" -o "$extra_ckpt_target"; then
    wget -O "$extra_ckpt_target" "$extra_ckpt_url" || true
  fi
fi

echo "Downloads complete."
