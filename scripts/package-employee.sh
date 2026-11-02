#!/bin/bash
set -euo pipefail
export AXIS_DISTRIBUTION=1
[[ "${AXIS_ADHOC_DEVELOPMENT:-0}" != 1 ]] || { echo "Distribution requires a permanent signing identity." >&2; exit 1; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { printf 'This package builds for Apple Silicon.\n' >&2; exit 1; }
source_dir="$repo_root/.build/whisper.cpp-1.9.5"
source_archive="$repo_root/.build/whisper-source.tar.gz"
build_dir="$repo_root/.build/whisper-portable"
mkdir -p "$repo_root/.build"
if [[ ! -f "$source_archive" ]]; then
    curl --fail --location --max-time 120 'https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz' -o "$source_archive"
fi
[[ "$(shasum -a 256 "$source_archive" | cut -d ' ' -f 1)" == ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720 ]] || { printf 'Source checksum mismatch\n' >&2; exit 1; }
if [[ ! -d "$source_dir" ]]; then tar -xzf "$source_archive" -C "$repo_root/.build"; fi
timeout 90 cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a -DGGML_OPENMP=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
timeout 300 cmake --build "$build_dir" --target whisper-cli -j 8
# Reject accidental Homebrew or build-directory linkage in a supposedly portable executable.
if otool -L "$build_dir/bin/whisper-cli" | tail -n +2 | awk '{print $1}' | rg -v '^(/usr/lib/|/System/Library/)'  ; then
    printf 'Non-system dynamic dependency detected.\n' >&2; exit 1
fi
AXIS_APP_OUTPUT="$repo_root/_output/AxisCopilot.app" bash "$repo_root/scripts/build-app.sh"
bash "$repo_root/scripts/setup-model.sh"
bash "$repo_root/scripts/setup-speakers.sh"
xcrun vtool -show-build "$build_dir/bin/whisper-cli" | rg -q "minos 15.0"
xcrun vtool -show-build "$repo_root/_output/AxisCopilot.app/Contents/MacOS/AxisCopilot" | rg -q "minos 15.0"
bundle_dir="$repo_root/_output/employee-arm64"
app_path="$bundle_dir/AxisCopilot.app"
mkdir -p "$bundle_dir"
ditto "$repo_root/_output/AxisCopilot.app" "$app_path"
mkdir -p "$app_path/Contents/Resources/Tools" "$app_path/Contents/Resources/Models" "$app_path/Contents/Resources/Licenses"
cp "$build_dir/bin/whisper-cli" "$app_path/Contents/Resources/Tools/whisper-cli"
cp "$HOME/Library/Application Support/AxisSalesCopilot/Models/ggml-small.bin" "$app_path/Contents/Resources/Models/ggml-small.bin"
ditto "$HOME/Library/Application Support/AxisCopilot/SpeakerModels" "$app_path/Contents/Resources/SpeakerModels"
cp "$source_dir/LICENSE" "$app_path/Contents/Resources/Licenses/whisper.cpp-MIT.txt"
cp "$repo_root/docs/EMPLOYEE-INSTALL.md" "$bundle_dir/INSTALL.md"
printf 'whisper.cpp 1.9.5: https://github.com/ggml-org/whisper.cpp\nModel: https://huggingface.co/ggerganov/whisper.cpp\n' > "$app_path/Contents/Resources/Licenses/SOURCES.txt"
bash "$repo_root/scripts/sign-app.sh" "$app_path"
"$app_path/Contents/MacOS/AxisCopilot" --diagnostics
# Real bundled inference; use a harmless generated fixture, never a client meeting.
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
timeout 30 say -v Milena -o "$fixture_dir/russian.aiff" 'Добрый день. Стоимость проекта составляет сто тысяч рублей. Срок выполнения работы четыре недели.'
timeout 30 ffmpeg -v error -i "$fixture_dir/russian.aiff" -ar 16000 -ac 1 "$fixture_dir/russian.wav"
timeout 120 "$app_path/Contents/MacOS/AxisCopilot" --verify-fixture "$fixture_dir/russian.wav"
archive="$repo_root/_output/2026-11-02_v5_AxisCopilot-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$bundle_dir" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
printf '%s\n' "$archive"
