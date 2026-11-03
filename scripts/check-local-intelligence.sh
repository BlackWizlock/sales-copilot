#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
timeout 180 swift build --build-system native --package-path "$root" --product CoreChecks
bin="$(swift build --build-system native --package-path "$root" --show-bin-path 2>/dev/null)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
timeout 90 swiftc -I "$bin/Modules" "$bin"/CopilotCore.build/*.o \
  "$root/Sources/AxisCopilot/Localization.swift" \
  "$root/Sources/AxisCopilot/IntelligenceSettings.swift" \
  "$root/Sources/AxisCopilot/LocalIntelligence.swift" \
  "$root/Sources/AxisCopilot/GroundedSummaryGenerator.swift" \
  "$root/Sources/AxisCopilot/MeetingChatController.swift" \
  "$root/Sources/AxisCopilot/MaterialTextExtractor.swift" \
  "$root/Tests/Integration/LocalGenerationChecks.swift" -o "$scratch/checks"
timeout 30 "$scratch/checks"
