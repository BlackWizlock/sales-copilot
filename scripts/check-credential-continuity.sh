#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
identity_file="${AXIS_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/AxisSalesCopilot/signing-identity.txt}"
identity="${AXIS_SIGNING_IDENTITY:-$(cat "$identity_file")}"
[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]]
timeout 180 swift build --build-system native --package-path "$root" --product CoreChecks
bin="$(swift build --build-system native --package-path "$root" --show-bin-path 2>/dev/null)"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
service="ru.axisconsult.copilot.continuity-test.$(uuidgen)"
trap 'if [[ -x "$scratch/build-a" && -f "$scratch/store/AxisCredentials" ]]; then timeout 8 "$scratch/build-a" cleanup "$service" "$scratch/helper-a" "$scratch/store" >/dev/null 2>&1 || true; fi; rm -rf "$scratch"' EXIT
common=(-D CREDENTIAL_FIXTURE -D CREDENTIAL_BRIDGE -I "$bin/Modules" "$bin"/CopilotCore.build/*.o "$root/Sources/AxisCopilot/CredentialWire.swift" "$root/Sources/AxisCopilot/CredentialBridge.swift" "$root/Sources/AxisCopilot/Localization.swift" "$root/Sources/AxisCopilot/KeychainAccess.swift" "$root/Sources/AxisCopilot/BitrixCredentials.swift" "$root/Tests/BitrixIntegration/CredentialContinuityChecks.swift")
timeout 90 swiftc "${common[@]}" -o "$scratch/build-a"
timeout 90 swiftc -D BUILD_B "${common[@]}" -o "$scratch/build-b"
timeout 90 swiftc -O -D CREDENTIAL_FIXTURE "$root/Sources/AxisCopilot/CredentialWire.swift" "$root/scripts/CredentialHelper.swift" -o "$scratch/helper-a"
cp "$scratch/helper-a" "$scratch/helper-b"
for helper in "$scratch/helper-a" "$scratch/helper-b"; do
 options=runtime
 [[ "$helper" != "$scratch/helper-b" ]] || options=runtime,kill
 timeout 30 codesign --force --sign "$identity" --timestamp=none --options "$options" --identifier ru.axisconsult.SalesCopilot.AxisCredentials --requirements "=designated => identifier \"ru.axisconsult.SalesCopilot.AxisCredentials\" and certificate leaf = H\"$identity\"" "$helper"
done
cp "$scratch/build-a" "$scratch/foreign"
for app in "$scratch/build-a" "$scratch/build-b"; do
 timeout 30 codesign --force --sign "$identity" --timestamp=none --options runtime --identifier ru.axisconsult.SalesCopilot --requirements "=designated => identifier \"ru.axisconsult.SalesCopilot\" and certificate leaf = H\"$identity\"" "$app"
done
timeout 30 codesign --force --sign "$identity" --timestamp=none --options runtime --identifier ru.axisconsult.synthetic.foreign "$scratch/foreign"
hash_of() { codesign -d --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
[[ "$(hash_of "$scratch/build-a")" != "$(hash_of "$scratch/build-b")" ]]
[[ "$(hash_of "$scratch/helper-a")" != "$(hash_of "$scratch/helper-b")" ]]
timeout 25 "$scratch/build-a" migration "$service" "$scratch/helper-a" "$scratch/store"
timeout 25 "$scratch/build-a" write "$service" "$scratch/helper-a" "$scratch/store"
before="$(shasum -a 256 "$scratch/store/AxisCredentials")"
timeout 25 "$scratch/build-a" read "$service" "$scratch/helper-a" "$scratch/store"
timeout 25 "$scratch/build-b" read "$service" "$scratch/helper-b" "$scratch/store"
[[ "$before" == "$(shasum -a 256 "$scratch/store/AxisCredentials")" ]]
timeout 25 "$scratch/foreign" foreign "$service" "$scratch/helper-a" "$scratch/store"
timeout 25 "$scratch/build-b" delete "$service" "$scratch/helper-b" "$scratch/store"
timeout 25 "$scratch/build-b" purge "$service" "$scratch/helper-b" "$scratch/store"
chmod u+w "$scratch/store/AxisCredentials"
printf x >> "$scratch/store/AxisCredentials"
timeout 25 "$scratch/build-b" tampered "$service" "$scratch/helper-b" "$scratch/store"
echo 'PASS: distinct signed app builds retain one immutable helper; foreign caller and tampering denied'
