#!/bin/bash
# Composites the README's popover screenshot from its layered source assets.
#
#     bash scripts/build-screenshot.sh
#
# Reads assets/source/screenshot-popover/{menu-bar,icon,icon-mask,popup}.png
# and writes assets/screenshot-popover.png.
#
# Canvas size is driven by popup.png (the layer most likely to change height
# as popover content grows/shrinks) — menu-bar.png and icon.png are extended
# or cropped to match, anchored top-left, since their content sits flush
# against the top and their padding below is transparent either way.
#
# icon-mask.png's alpha channel replaces icon.png's own alpha before
# compositing, so icon.png's rectangular capture bounds never show as a seam
# — only the glyph silhouette from icon-mask.png is drawn onto menu-bar.png.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="assets/source/screenshot-popover"
OUT="assets/screenshot-popover.png"

for f in menu-bar icon icon-mask popup; do
  [ -f "$SRC/$f.png" ] || { echo "error: missing $SRC/$f.png"; exit 1; }
done

WIDTH=$(magick identify -format "%w" "$SRC/popup.png")
HEIGHT=$(magick identify -format "%h" "$SRC/popup.png")
echo "→ Canvas: ${WIDTH}x${HEIGHT} (from popup.png)"

BUILD_DIR=$(mktemp -d /tmp/claude_stats_screenshot.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

magick "$SRC/menu-bar.png" -gravity NorthWest -background none -extent "${WIDTH}x${HEIGHT}" "$BUILD_DIR/menu-bar.png"
magick "$SRC/icon.png" -gravity NorthWest -background none -extent "${WIDTH}x${HEIGHT}" "$BUILD_DIR/icon.png"
magick "$SRC/icon-mask.png" -gravity NorthWest -background none -extent "${WIDTH}x${HEIGHT}" "$BUILD_DIR/icon-mask.png"

echo "→ Masking icon..."
magick "$BUILD_DIR/icon.png" \( "$BUILD_DIR/icon-mask.png" -alpha extract \) \
  -alpha off -compose CopyOpacity -composite "$BUILD_DIR/icon-masked.png"

echo "→ Compositing menu bar + icon + popup..."
magick "$BUILD_DIR/menu-bar.png" "$BUILD_DIR/icon-masked.png" -composite \
  "$SRC/popup.png" -composite "$OUT"

echo "→ Wrote $OUT"
