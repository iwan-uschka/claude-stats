#!/bin/bash
# Regenerates the AppIcon PNGs (three generic bars, no Claude branding — see
# scripts/make_icon.swift for why). Run after changing that file.
#
#     bash scripts/make_icon.sh
#
# The generated PNGs are committed, so make_app.sh never needs this script —
# it only needs `actool` and the checked-in asset catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

BUILD_DIR=$(mktemp -d /tmp/claude_stats_icon.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "→ Compiling the icon renderer..."
# swiftc only allows top-level statements in a file literally named main.swift,
# so the renderer is copied under that name rather than kept as one in the repo
# (scripts/main.swift would be a useless filename to read in a diff).
cp scripts/make_icon.swift "$BUILD_DIR/main.swift"

swiftc -O -o "$BUILD_DIR/make_icon" "$BUILD_DIR/main.swift"

echo "→ Rendering icon sizes..."
"$BUILD_DIR/make_icon" "$REPO_ROOT"
