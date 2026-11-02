#!/bin/bash
# Local owner release pipeline. Hosting deployment remains a separate reviewed operation.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
kind="${1:-}"
case "$kind" in patch|minor|major) ;; *) printf 'Usage: bash scripts/publish-update.sh patch|minor|major [output-directory]\n' >&2; exit 2 ;; esac
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :AxisUpdateFeedURL' "$repo_root/Resources/Info.plist")"
[[ "$feed_url" == https://* ]] || { printf 'Configure HTTPS AxisUpdateFeedURL before building a release.\n' >&2; exit 1; }
output_dir="${2:-$repo_root/_output/update-channel}"
python3 "$repo_root/scripts/publish-update.py" --bump "$kind" --plist "$repo_root/Resources/Info.plist"
timeout 1200 bash "$repo_root/scripts/ci-local.sh"
timeout 1200 bash "$repo_root/scripts/package-employee.sh"
python3 "$repo_root/scripts/publish-update.py" "$repo_root/_output/employee-arm64/AxisCopilot.app" --output "$output_dir" --feed-url "$feed_url"
printf 'Local signed release prepared. Deploy archive first and manifest last following docs/UPDATES.md.\n'
