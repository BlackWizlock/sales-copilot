#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_args=(--build-system native -c release)
if [[ -n "${AXIS_SWIFT_SCRATCH_PATH:-}" ]]; then build_args+=(--scratch-path "$AXIS_SWIFT_SCRATCH_PATH"); fi
timeout 600 swift build "${build_args[@]}" --product AxisCopilot
bin_dir="$(swift build "${build_args[@]}" --show-bin-path 2>/dev/null)"
app_path="${AXIS_APP_OUTPUT:-$repo_root/_output/AxisCopilot.app}"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# SwiftPM license/resources may be read-only; allow rebuilding our generated bundle.
chmod -R u+w "$app_path"
cp "$bin_dir/AxisCopilot" "$app_path/Contents/MacOS/AxisCopilot"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Resources/axis_sign.png" "$app_path/Contents/Resources/axis_sign.png"
cp "$repo_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
for locale in "$repo_root/Resources/"*.lproj; do
    [[ ! -d "$locale" ]] || ditto "$locale" "$app_path/Contents/Resources/$(basename "$locale")"
done
# SwiftPM resources (tokenizers, privacy manifests) must travel with the executable.
for resource in "$bin_dir/"*.bundle; do
    [[ ! -d "$resource" ]] || ditto "$resource" "$app_path/Contents/Resources/$(basename "$resource")"
done
notices_dir="$app_path/Contents/Resources/ThirdPartyNotices"
for checkout in "${AXIS_SWIFT_SCRATCH_PATH:-$repo_root/.build}/checkouts/"*; do
    [[ -d "$checkout" ]] || continue
    for notice in "$checkout"/LICENSE* "$checkout"/LICENCE* "$checkout"/NOTICE* "$checkout"/COPYING* "$checkout"/license* "$checkout"/notice*; do
        [[ -f "$notice" ]] || continue
        mkdir -p "$notices_dir/$(basename "$checkout")"
        cp "$notice" "$notices_dir/$(basename "$checkout")/"
    done
done
mkdir -p "$app_path/Contents/Resources/Tools"
swiftc -O -target arm64-apple-macosx15.0 "$repo_root/Sources/AxisCopilot/UpdateSupport.swift" "$repo_root/scripts/UpdateHelper.swift" -o "$app_path/Contents/Resources/Tools/AxisUpdater"
timeout 90 swiftc -O -target arm64-apple-macosx15.0 "$repo_root/Sources/AxisCopilot/CredentialWire.swift" "$repo_root/scripts/CredentialHelper.swift" -o "$app_path/Contents/Resources/Tools/AxisCredentials"
bash "$repo_root/scripts/setup-intelligence.sh" "$app_path"
bash "$repo_root/scripts/sign-app.sh" "$app_path"
printf '%s\n' "$app_path"
