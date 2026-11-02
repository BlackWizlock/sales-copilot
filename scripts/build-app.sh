#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
timeout 240 swift build --build-system native -c release --product AxisCopilot
bin_dir="$(swift build --build-system native -c release --show-bin-path 2>/dev/null)"
app_path="$repo_root/_output/AxisCopilot.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/AxisCopilot" "$app_path/Contents/MacOS/AxisCopilot"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Resources/axis_sign.png" "$app_path/Contents/Resources/axis_sign.png"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
