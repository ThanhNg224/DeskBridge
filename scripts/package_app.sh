#!/usr/bin/env bash
# Builds build/DeskBridge.app. Accessibility/Input Monitoring grants attach to the signed bundle,
# so use a stable identity to keep them across rebuilds:
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/package_app.sh
# The default ad-hoc identity ("-") changes on every build and resets the permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DeskBridge.app"

"$ROOT/scripts/build_server.sh"
swift build -c release --package-path "$ROOT/mac"
BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)/DeskBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskBridge"
cp "$ROOT/server/build/deskbridge-server.jar" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.deskbridge.app</string>
  <key>CFBundleName</key><string>DeskBridge</string>
  <key>CFBundleExecutable</key><string>DeskBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
