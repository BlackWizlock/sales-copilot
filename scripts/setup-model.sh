#!/bin/bash
set -euo pipefail
model_dir="$HOME/Library/Application Support/AxisSalesCopilot/Models"
model_path="$model_dir/ggml-small.bin"
expected=1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b
mkdir -p "$model_dir"
chmod 700 "$model_dir"
if [[ -f "$model_path" ]] && [[ "$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)" == "$expected" ]]; then
    printf 'Model already verified.\n'; exit 0
fi
tmp_path="$(mktemp "$model_dir/download.XXXXXX")"
trap 'rm -f "$tmp_path"' EXIT
curl --fail --location --max-time 600 --retry 2 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin' -o "$tmp_path"
[[ "$(shasum -a 256 "$tmp_path" | cut -d ' ' -f 1)" == "$expected" ]] || { printf 'Model checksum mismatch\n' >&2; exit 1; }
chmod 600 "$tmp_path"
mv "$tmp_path" "$model_path"
printf 'Multilingual small model installed and verified.\n'
