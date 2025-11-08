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

echo "Downloads complete."
