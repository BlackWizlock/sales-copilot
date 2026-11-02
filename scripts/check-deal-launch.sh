#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
timeout 180 swift build --build-system native --package-path "$root" --product CoreChecks
bin="$(timeout 30 swift build --build-system native --package-path "$root" --show-bin-path 2>/dev/null)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
core=("$bin"/CopilotCore.build/*.o)
timeout 90 swiftc -I "$bin/Modules" "${core[@]}" "$root/Sources/AxisCopilot/Localization.swift" \
    "$root/Sources/AxisCopilot/BitrixCredentials.swift" \
    "$root/Sources/AxisCopilot/KeychainAccess.swift" \
    "$root/Sources/AxisCopilot/BitrixClient.swift" \
    "$root/Sources/AxisCopilot/CRMController.swift" \
    "$root/Tests/Integration/DealLaunchChecks.swift" -o "$scratch/deal-launch"
timeout 45 "$scratch/deal-launch"
