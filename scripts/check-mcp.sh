#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
timeout 180 swift build --build-system native --package-path "$root" --product CoreChecks
bin="$(swift build --build-system native --package-path "$root" --show-bin-path 2>/dev/null)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
core=("$bin"/CopilotCore.build/*.o)
timeout 90 swiftc -D MCP_PROTOCOL_STANDALONE -I "$bin/Modules" "${core[@]}" "$root/Sources/AxisCopilot/MCPServer.swift" "$root/Tests/CopilotCoreTests/MCPTests.swift" -o "$scratch/mcp-checks"
timeout 30 "$scratch/mcp-checks"
