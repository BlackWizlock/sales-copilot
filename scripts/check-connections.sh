#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
timeout 180 swift build --build-system native --package-path "$root" --product CoreChecks
bin="$(swift build --build-system native --package-path "$root" --show-bin-path 2>/dev/null)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
core=("$bin"/CopilotCore.build/*.o)
common=(-I "$bin/Modules" "${core[@]}" "$root/Sources/AxisCopilot/Localization.swift" "$root/Sources/AxisCopilot/BitrixCredentials.swift" "$root/Sources/AxisCopilot/KeychainAccess.swift")
timeout 90 swiftc "${common[@]}" "$root/Tests/BitrixIntegration/BitrixKeychainChecks.swift" -o "$scratch/keychain"
timeout 30 "$scratch/keychain"
timeout 90 swiftc -I "$bin/Modules" "${core[@]}" "$root/Sources/AxisCopilot/Localization.swift" "$root/Sources/AxisCopilot/KeychainAccess.swift" "$root/Sources/AxisCopilot/OpenRouterClient.swift" "$root/Tests/BitrixIntegration/OpenRouterKeychainChecks.swift" -o "$scratch/openrouter-keychain"
timeout 30 "$scratch/openrouter-keychain"
timeout 90 swiftc "${common[@]}" "$root/Sources/AxisCopilot/BitrixClient.swift" "$root/Sources/AxisCopilot/CRMController.swift" "$root/Tests/BitrixIntegration/CRMTransportChecks.swift" -o "$scratch/transport"
timeout 60 "$scratch/transport"

timeout 90 swiftc -I "$bin/Modules" "${core[@]}" "$root/Sources/AxisCopilot/Localization.swift" "$root/Sources/AxisCopilot/KeychainAccess.swift" "$root/Sources/AxisCopilot/OpenRouterClient.swift" "$root/Tests/Integration/OpenRouterCatalogChecks.swift" -o "$scratch/openrouter-catalog"
timeout 30 "$scratch/openrouter-catalog"

timeout 90 swiftc "${common[@]}" "$root/Sources/AxisCopilot/BitrixClient.swift" "$root/Sources/AxisCopilot/CRMController.swift" "$root/Tests/BitrixIntegration/CRMIsolationChecks.swift" -o "$scratch/isolation"
timeout 30 "$scratch/isolation"

timeout 90 swiftc "${common[@]}" "$root/Sources/AxisCopilot/BitrixClient.swift" "$root/Sources/AxisCopilot/CRMController.swift" "$root/Tests/BitrixIntegration/CalendarControllerChecks.swift" -o "$scratch/calendar"
timeout 30 "$scratch/calendar"
timeout 90 swiftc "${common[@]}" "$root/Sources/AxisCopilot/BitrixClient.swift" "$root/Sources/AxisCopilot/CRMController.swift" "$root/Tests/BitrixIntegration/CalendarEditingChecks.swift" -o "$scratch/calendar-editing"
timeout 45 "$scratch/calendar-editing"

# Different ad-hoc identities reproduce a rebuild ACL mismatch without reading real keys.
timeout 90 swiftc -D KEYCHAIN_FIXTURE_WRITER "${common[@]}" "$root/Tests/BitrixIntegration/KeychainQuietChecks.swift" -o "$scratch/quiet-writer"
timeout 90 swiftc "${common[@]}" "$root/Tests/BitrixIntegration/KeychainQuietChecks.swift" -o "$scratch/quiet-reader"
codesign --force --sign - --identifier ru.axisconsult.synthetic.writer "$scratch/quiet-writer"
codesign --force --sign - --identifier ru.axisconsult.synthetic.reader "$scratch/quiet-reader"
service="ru.axisconsult.copilot.quiet-test.$(uuidgen)"
trap '"$scratch/quiet-writer" --delete "$service" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
timeout 10 "$scratch/quiet-writer" "$service"
timeout 10 "$scratch/quiet-reader" "$service"
