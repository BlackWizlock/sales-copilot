#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
swiftc "$root/Sources/AxisCopilot/UpdateSupport.swift" "$root/scripts/UpdateHelper.swift" -o "$fixture/updater"
# No unsigned or malformed input may become an update, even if named .app.
mkdir "$fixture/Broken.app"
if "$fixture/updater" validate "$fixture/Broken.app" "$fixture/Broken.app"; then
    echo 'FAIL: malformed update accepted' >&2; exit 1
fi
swiftc "$root/Sources/AxisCopilot/UpdateSupport.swift" "$root/scripts/UpdateChecks.swift" -o "$fixture/checks"
"$fixture/checks" "$fixture"
# Real signatures and architectures. Skip explicitly on a CI Mac without a key.
identity_file="${AXIS_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/AxisSalesCopilot/signing-identity.txt}"
if [[ ! -s "$identity_file" && -z "${AXIS_SIGNING_IDENTITY:-}" ]]; then
    echo 'SKIP signed fixtures: no local identity. Run setup-signing.sh to exercise real signatures.'
    exit 0
fi
python3 - "$fixture" <<'PY'
import pathlib, plistlib, sys
root=pathlib.Path(sys.argv[1])
for name, version in [('Current','1'),('New','2'),('Old','0'),('WrongArch','2'),('OtherSigner','2'),('Tampered','2'),('Adhoc','2'),('WrongID','2')]:
    app=root/(name+'.app')/'Contents'
    (app/'MacOS').mkdir(parents=True)
    with (app/'Info.plist').open('wb') as out:
        plistlib.dump(dict(CFBundleIdentifier='ru.axisconsult.SalesCopilot',CFBundleVersion=version,CFBundleExecutable='AxisCopilot',CFBundlePackageType='APPL'),out)
(root/'main.c').write_text('int main(void) { return 0; }\n')
PY
clang -target arm64-apple-macos15.0 "$fixture/main.c" -o "$fixture/arm64"
clang -target x86_64-apple-macos15.0 "$fixture/main.c" -o "$fixture/x86_64"
for name in Current New Old WrongArch OtherSigner Tampered Adhoc WrongID; do
    arch=arm64; [[ "$name" != WrongArch ]] || arch=x86_64
    cp "$fixture/$arch" "$fixture/$name.app/Contents/MacOS/AxisCopilot"
    bash "$root/scripts/sign-app.sh" "$fixture/$name.app"
done
AXIS_ADHOC_DEVELOPMENT=1 bash "$root/scripts/sign-app.sh" "$fixture/Adhoc.app"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier ru.axisconsult.OtherApp' "$fixture/WrongID.app/Contents/Info.plist"
bash "$root/scripts/sign-app.sh" "$fixture/WrongID.app"
printf 'changed' >> "$fixture/Tampered.app/Contents/Info.plist"
# Isolated disposable signer. No login/default keychain or trust settings changed.
password="$(/usr/bin/openssl rand -hex 24)"
keychain="$fixture/test.keychain-db"
cleanup() { security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$fixture"; }
trap cleanup EXIT
security create-keychain -p "$password" "$keychain"
security unlock-keychain -p "$password" "$keychain"
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj '/CN=Axis Update Synthetic Test/' \
    -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=codeSigning' \
    -keyout "$fixture/test-key.pem" -out "$fixture/test-cert.pem" 2>/dev/null
export AXIS_TEST_P12_PASSWORD="$password"
/usr/bin/openssl pkcs12 -export -inkey "$fixture/test-key.pem" -in "$fixture/test-cert.pem" \
    -out "$fixture/test.p12" -passout env:AXIS_TEST_P12_PASSWORD
security import "$fixture/test.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
other_identity="$(/usr/bin/openssl x509 -in "$fixture/test-cert.pem" -noout -fingerprint -sha1 | cut -d = -f 2 | tr -d :)"
AXIS_SIGNING_IDENTITY="$other_identity" AXIS_SIGNING_KEYCHAIN="$keychain" bash "$root/scripts/sign-app.sh" "$fixture/OtherSigner.app"
unset AXIS_TEST_P12_PASSWORD password
"$fixture/updater" validate "$fixture/Current.app" "$fixture/New.app"
echo 'PASS valid same-certificate signed update'
for name in Old WrongArch OtherSigner Tampered Adhoc WrongID; do
    if "$fixture/updater" validate "$fixture/Current.app" "$fixture/$name.app"; then
        echo "FAIL: accepted $name" >&2; exit 1
    fi
    echo "PASS rejected $name"
done
# Different contents/CDHashes retain exactly the same designated requirement.
codesign -d -r- "$fixture/Current.app" 2> "$fixture/current-dr"
codesign -d -r- "$fixture/New.app" 2> "$fixture/new-dr"
sed -n '/^designated =>/p' "$fixture/current-dr" > "$fixture/dr1"
sed -n '/^designated =>/p' "$fixture/new-dr" > "$fixture/dr2"
[[ -s "$fixture/dr1" ]]
cmp "$fixture/dr1" "$fixture/dr2"
echo 'PASS stable designated requirement across different builds'

"$fixture/checks" "$fixture" signed
echo "Update checks passed"
