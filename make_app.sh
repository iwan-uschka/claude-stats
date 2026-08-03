#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# BSD mktemp only substitutes trailing X's, so make a temp dir and place the .plist inside it.
PARTIAL_DIR=$(mktemp -d /tmp/claude_stats_partial.XXXXXX)
PARTIAL_PLIST="$PARTIAL_DIR/partial.plist"
trap 'rm -rf "$PARTIAL_DIR"' EXIT

# Version comes from make_release.sh as $1; standalone runs derive it from the
# latest release heading in CHANGELOG.md.
VERSION="${1:-$(grep -oE '\[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | head -1 | tr -d '[]' || true)}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid or missing version '${VERSION}' — pass x.y.z as \$1 or release it in CHANGELOG.md"
  exit 1
fi
echo "→ Version: ${VERSION}"

echo "→ Building release binary..."
swift build -c release

echo "→ Assembling ClaudeStats.app..."
rm -rf ClaudeStats.app
mkdir -p ClaudeStats.app/Contents/MacOS
mkdir -p ClaudeStats.app/Contents/Resources

cp .build/release/ClaudeStats ClaudeStats.app/Contents/MacOS/ClaudeStats

# SettingsView resolves this itself (doesn't use SwiftPM's generated
# Bundle.module accessor — it only checks Bundle.main.bundleURL, the .app's
# own root, and a baked-in `.build/...` path that only exists on this
# machine). Contents/Resources is the conventional, codesign-sealed location.
# Keep in sync with SettingsView.bundledScriptURL()'s `bundleName` — SwiftPM
# derives this name from the package/target names in Package.swift.
RESOURCE_BUNDLE=".build/release/ClaudeStats_ClaudeStats.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "error: $RESOURCE_BUNDLE missing — Settings' script reveal would ship broken"
  exit 1
fi
echo "→ Bundling resources..."
cp -R "$RESOURCE_BUNDLE" ClaudeStats.app/Contents/Resources/

echo "→ Compiling asset catalog..."
xcrun actool \
  --output-format human-readable-text \
  --notices --warnings \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  --app-icon AppIcon \
  --compress-pngs \
  --enable-on-demand-resources NO \
  --target-device mac \
  --minimum-deployment-target 14.0 \
  --platform macosx \
  --compile ClaudeStats.app/Contents/Resources \
  Sources/ClaudeStats/Assets.xcassets

# LSUIElement duplicates what `NSApplication.setActivationPolicy(.accessory)`
# already does in ClaudeStatsApp.swift, but it does so *earlier*: the plist key
# is read by launchd before any of our code runs, so the app never flashes a
# Dock tile or steals focus during the launch it takes us to call the API. It
# also keeps ClaudeStats out of the Cmd-Tab switcher for the same window. Cheap
# belt-and-braces; the runtime call stays as the authority for `swift run`
# builds, which have no bundle and therefore no plist.
cat > ClaudeStats.app/Contents/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudeStats</string>
  <key>CFBundleIdentifier</key><string>de.bitgrip.claude-stats</string>
  <key>CFBundleName</key><string>ClaudeStats</string>
  <key>CFBundleDisplayName</key><string>ClaudeStats</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

if [ -f "$PARTIAL_PLIST" ]; then
  if ! /usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" ClaudeStats.app/Contents/Info.plist; then
    echo "warning: could not merge asset catalog partial plist — app icon keys may be missing from Info.plist"
  fi
fi

# The repo has no LICENSE yet. Bundle one the moment it appears rather than
# silently shipping binaries without it — but don't hard-fail the build on a
# file that has never existed.
if [ -f LICENSE ]; then
  echo "→ Bundling LICENSE..."
  cp LICENSE ClaudeStats.app/Contents/Resources/LICENSE
fi

echo "→ Ad-hoc signing..."
codesign --sign - --force ClaudeStats.app

echo "✓ ClaudeStats.app is ready"
echo "  To share: zip -r ClaudeStats.zip ClaudeStats.app"
