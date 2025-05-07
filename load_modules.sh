#!/bin/bash
# Loads and sources modules from manifest.json

MODULE_PATH="/root/base/modules"
MANIFEST="/root/base/manifest.json"

echo "[INFO] Loading modules from manifest.json..."

jq -c '.modules[]' "$MANIFEST" | while read -r module; do
  id=$(echo "$module" | jq -r .id)
  file=$(echo "$module" | jq -r .file)
  desc=$(echo "$module" | jq -r .desc)
  full_path="$MODULE_PATH/$file"

  if [[ -f "$full_path" ]]; then
    echo "[+] [$id] Found $file — $desc"
    source "$full_path"
  else
    echo "[✗] [$id] MISSING: $file"
    exit 1
  fi
done

echo "[✓] All modules sourced."
