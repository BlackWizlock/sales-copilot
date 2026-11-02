#!/bin/bash
# The identity hash is public; its private key stays in the build Mac's Keychain.
set -euo pipefail
app="${1:?Usage: sign-app.sh /path/AxisCopilot.app}"
identity_file="${AXIS_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/AxisSalesCopilot/signing-identity.txt}"
identity="${AXIS_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$identity_file" ]]; then identity="$(cat "$identity_file")"; fi
if [[ "${AXIS_ADHOC_DEVELOPMENT:-0}" == 1 ]]; then
    [[ "${AXIS_DISTRIBUTION:-0}" != 1 ]] || { echo 'Ad-hoc signing is forbidden for distribution.' >&2; exit 1; }
    echo 'Explicit ad-hoc development build; stable permission identity and updates unavailable.' >&2
    identity=-
else
    [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo 'Permanent signing identity required. Run bash scripts/setup-signing.sh first. No ad-hoc fallback.' >&2; exit 1; }
fi
signing_options=(--timestamp=none)
if [[ -n "${AXIS_SIGNING_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$AXIS_SIGNING_KEYCHAIN"); fi
sign() {
    local target="$1"
    if [[ "$identity" == - ]]; then
        /usr/bin/codesign --force --sign - "$target"
    else
        # Explicit stable DR: unchanged between builds with this ID and certificate.
        local identifier
        if [[ "$target" == "$app" ]]; then identifier=ru.axisconsult.SalesCopilot; else identifier="ru.axisconsult.SalesCopilot.$(basename "$target")"; fi
        /usr/bin/codesign --force --sign "$identity" "${signing_options[@]}" --identifier "$identifier" \
            --requirements "=designated => identifier \"$identifier\" and certificate leaf = H\"$identity\"" "$target"
    fi
}
for executable in "$app/Contents/Resources/Tools/AxisUpdater" "$app/Contents/Resources/Tools/whisper-cli"; do
    if [[ -f "$executable" ]]; then sign "$executable"; fi
done
if [[ -d "$app/Contents/Resources/Tools/Ollama" ]]; then
    while IFS= read -r -d '' target; do
        if /usr/bin/file -b "$target" | /usr/bin/grep -q 'Mach-O'; then sign "$target"; fi
    done < <(/usr/bin/find "$app/Contents/Resources/Tools/Ollama" -type f -print0)
fi
sign "$app"
/usr/bin/codesign --verify --deep --strict "$app"
