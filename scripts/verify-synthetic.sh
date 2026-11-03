#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
timeout 30 say -v Milena -o "$fixture_dir/russian.aiff" 'Добрый день, мы обсуждаем коммерческое предложение. Стоимость проекта составляет сто тысяч рублей. Срок выполнения работы четыре недели.'
timeout 30 ffmpeg -v error -i "$fixture_dir/russian.aiff" -ar 16000 -ac 1 "$fixture_dir/russian.wav"
timeout 120 "$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --verify-fixture "$fixture_dir/russian.wav"
