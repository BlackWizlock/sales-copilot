#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
timeout 180 swift run --build-system native CoreChecks
python3 "$repo_root/scripts/check-localizations.py"
bash "$repo_root/scripts/check-materials.sh"
bash "$repo_root/scripts/check-connections.sh"
bash "$repo_root/scripts/check-mcp.sh"
bash "$repo_root/scripts/check-deal-launch.sh"
bash scripts/build-app.sh
"$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --diagnostics
"$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --verify-voice-processing
"$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --verify-playback
"$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --verify-recording-hud
bash "$repo_root/scripts/check-updates.sh"
bash "$repo_root/scripts/verify-synthetic.sh"
