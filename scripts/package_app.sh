#!/usr/bin/env bash
# Builds build/DeskBridge.app. Accessibility/Input Monitoring grants attach to the signed bundle, so sign
# with a stable identity: run scripts/setup_signing.sh once (creates "DeskBridge Dev"), or pass
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/package_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DeskBridge.app"

"$ROOT/scripts/build_server.sh"
swift build -c release --package-path "$ROOT/mac"
BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)/DeskBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskBridge"
cp "$ROOT/server/build/deskbridge-server.jar" "$ROOT/mac/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ROOT"/mac/Resources/*.lproj "$APP/Contents/Resources/"

VERSION="$(cat "$ROOT/VERSION")"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.deskbridge.app</string>
  <key>CFBundleName</key><string>DeskBridge</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array>
  <key>CFBundleExecutable</key><string>DeskBridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Identity: $CODESIGN_IDENTITY, else the local "DeskBridge Dev" (scripts/setup_signing.sh), else ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -p codesigning | grep -q '"DeskBridge Dev"'; then IDENTITY="DeskBridge Dev"; else IDENTITY="-"; fi
fi
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc: bind the signature to the bundle id instead of the binary hash so grants survive rebuilds.
  codesign --force --sign - --requirements '=designated => identifier "com.deskbridge.app"' "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
echo "Signed with: $IDENTITY"
echo "Built $APP"
