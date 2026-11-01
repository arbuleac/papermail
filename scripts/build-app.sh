#!/usr/bin/env bash
# Assemble dist/SuperSparrow.app from the SwiftPM build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product SuperSparrow
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/SuperSparrow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SuperSparrow" "$APP/Contents/MacOS/SuperSparrow"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# SwiftPM resource bundles (if any target declares resources) sit next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/" || true
done
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi
# Ad-hoc signature so Keychain, notifications and WebKit behave like a real app. Replace with a
# Developer ID identity for distribution: CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh release
codesign --force --sign "${CODESIGN_IDENTITY:--}" --entitlements "$ROOT/Resources/SuperSparrow.entitlements" "$APP" >/dev/null
echo "$APP"
