#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
timeout 180 swift run --build-system native CoreChecks
bash scripts/build-app.sh
"$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --diagnostics
bash "$repo_root/scripts/verify-synthetic.sh"
