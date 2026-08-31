#!/bin/bash
# Renders the README's images from the app's own views and mock data.
#
#     bash scripts/render-readme-assets.sh [output-dir]
#
# Writes, for each of the light and dark system appearances:
#   assets/screenshot-popover-<theme>.png   menu bar strip + glyph + popover
#   assets/menu-bar-glyph-<theme>.png       the glyph alone, transparent
#
# The renderer lives in the test target — Tests/ClaudeStatsTests/
# ReadmeAssetRenderTests.swift — because `ClaudeStats` is an executableTarget
# and no second executable can depend on it; `@testable import` there reaches
# the views and the `#if DEBUG` AppModel.previewShowcase() fixture without
# making any of it public. Nothing of it ships in ClaudeStats.app.
#
# Run this by hand when the popover's layout changes. Deliberately NOT wired
# into make_app.sh or make_release.sh: make_release.sh refuses a dirty tree, so
# regenerating committed PNGs mid-release would break the release.
#
# Output is deterministic (the renderer pins its clock), so a second run on an
# unchanged UI leaves the tree clean.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-$PWD/assets}"
mkdir -p "$OUT_DIR"

echo "→ Rendering into $OUT_DIR"
CLAUDE_STATS_RENDER_ASSETS="$OUT_DIR" \
  swift test --filter ReadmeAssetRenderTests

echo "✓ Wrote:"
for theme in light dark; do
  echo "    $OUT_DIR/screenshot-popover-$theme.png"
  echo "    $OUT_DIR/menu-bar-glyph-$theme.png"
done
