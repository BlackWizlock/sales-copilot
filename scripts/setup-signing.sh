#!/bin/bash
# One build Mac owns the permanent certificate. Never distribute or commit its key.
set -euo pipefail
identity_file="${AXIS_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/AxisSalesCopilot/signing-identity.txt}"
pending="$identity_file.pending"
identity="${AXIS_SIGNING_IDENTITY:-}"
if [[ -s "$identity_file" ]]; then identity="$(cat "$identity_file")"; fi
if [[ -z "$identity" && -s "$pending" ]]; then identity="$(cat "$pending")"; fi
keychain="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$keychain" ]] || { echo 'Login Keychain not found. Create/unlock it in Keychain Access.' >&2; exit 1; }
workspace="$(mktemp -d)"
chmod 700 "$workspace"
trap 'rm -rf "$workspace"' EXIT
if [[ -z "$identity" ]]; then
    # Password protects only temporary PKCS12 transport; never printed/persisted.
    export AXIS_TEMP_P12_PASSWORD
    AXIS_TEMP_P12_PASSWORD="$(/usr/bin/openssl rand -hex 32)"
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 7300 \
        -subj '/CN=Axis Consult Local Application Signing/' \
        -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=codeSigning' \
        -keyout "$workspace/key.pem" -out "$workspace/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$workspace/key.pem" -in "$workspace/cert.pem" \
        -out "$workspace/identity.p12" -passout env:AXIS_TEMP_P12_PASSWORD
    # May show a system authorization dialog. No trust settings are changed.
    /usr/bin/security import "$workspace/identity.p12" -k "$keychain" -P "$AXIS_TEMP_P12_PASSWORD" -T /usr/bin/codesign
    identity="$(/usr/bin/openssl x509 -in "$workspace/cert.pem" -noout -fingerprint -sha1 | cut -d = -f 2 | tr -d :)"
    mkdir -p "$(dirname "$identity_file")"
    # A failed probe must not generate another identity on the next invocation.
    (umask 077; printf '%s\n' "$identity" > "$pending")
    unset AXIS_TEMP_P12_PASSWORD
fi
[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || { echo 'Invalid public signing certificate fingerprint.' >&2; exit 1; }
cp /usr/bin/true "$workspace/signing-probe"
# Prove use, not Apple trust. Self-signed identities can be absent from find-identity -v.
if ! timeout 30 /usr/bin/codesign --force --sign "$identity" --timestamp=none \
    --requirements "=designated => identifier \"axis.signing.probe\" and certificate leaf = H\"$identity\"" \
    --identifier axis.signing.probe "$workspace/signing-probe"; then
    echo 'Identity imported but signing probe failed. If macOS asks, authorize only this key for /usr/bin/codesign in Keychain Access and rerun. Do not change certificate trust. Identity is preserved for retry.' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$workspace/signing-probe"
mkdir -p "$(dirname "$identity_file")"
(umask 077; printf '%s\n' "$identity" > "$identity_file")
echo 'Permanent local signing identity configured. Private key remains in login Keychain.'
