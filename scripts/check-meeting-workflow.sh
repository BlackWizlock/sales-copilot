#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${AXIS_COPILOT_ALLOW_PAID_SYNTHETIC_TEST:-0}" == 1 ]] || {
    echo 'Paid synthetic workflow is opt-in; no model request was sent.' >&2
    exit 1
}
# Use the signed .app identity, stable credential helper and the app preference domain.
# The owner must first choose the model, enable allowed data and set a budget in settings.
bash "$root/scripts/build-app.sh"
timeout 900 "$root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" --verify-meeting-workflow
