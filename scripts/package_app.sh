#!/usr/bin/env bash
# Builds build/DeskBridge.app. Accessibility/Input Monitoring grants attach to the signed bundle, so sign
# with a stable identity: run scripts/setup_signing.sh once (creates "DeskBridge Dev"), or pass
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/package_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${DESKBRIDGE_APP_OUTPUT:-$ROOT/build/DeskBridge.app}"
APP_DIR="$(dirname "$APP")"

# Fail rather than silently replacing an existing developer signature with ad-hoc signing.
# find-identity without -v includes usable self-signed identities that are not trusted system-wide.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITIES="$(security find-identity -p codesigning | awk '/"DeskBridge Dev"/ && !seen[$2]++ { print $2 }')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | awk 'NF { n++ } END { print n+0 }')"
  if [ "$COUNT" -ne 1 ]; then
    echo 'Expected one DeskBridge Dev signing identity. Run scripts/setup_signing.sh, or set CODESIGN_IDENTITY explicitly.' >&2
    exit 1
  fi
  IDENTITY="$IDENTITIES"
fi

"$ROOT/scripts/build_server.sh"
swift build -c release --package-path "$ROOT/mac"
BIN_DIR="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)"
BIN="$BIN_DIR/DeskBridge"

# Assemble and verify away from the active app: a build or signing failure must leave it intact.
mkdir -p "$APP_DIR"
STAGE="$(mktemp -d "$APP_DIR/.package.XXXXXX")"
cleanup() {
  if [ -e "$STAGE/previous.app" ] && [ ! -e "$APP" ]; then
    if ! mv "$STAGE/previous.app" "$APP"; then
      echo "Could not restore previous app; it remains at $STAGE/previous.app" >&2
      return
    fi
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
BUNDLE="$STAGE/DeskBridge.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/DeskBridge"
cp "$ROOT/server/build/deskbridge-server.jar" "$ROOT/mac/Resources/AppIcon.icns" "$ROOT/mac/Resources/ThirdPartyNotices.txt" "$BUNDLE/Contents/Resources/"
cp -R "$ROOT"/mac/Resources/*.lproj "$BUNDLE/Contents/Resources/"
cp -R "$BIN_DIR/ZIPFoundation_ZIPFoundation.bundle" "$BUNDLE/Contents/Resources/"

VERSION="$(cat "$ROOT/VERSION")"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
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
</dict>
</plist>
PLIST

# Explicit ad-hoc signing is used by the release script; local builds use the stable identity above.
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --requirements '=designated => identifier "com.deskbridge.app"' "$BUNDLE"
elif [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BUNDLE"
else
  codesign --force --sign "$IDENTITY" "$BUNDLE"
fi
codesign --verify --strict "$BUNDLE"

# Keep the previous bundle until installation has succeeded, and restore it if the move fails.
if [ -e "$APP" ]; then mv "$APP" "$STAGE/previous.app"; fi
if ! mv "$BUNDLE" "$APP"; then
  if [ -e "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP"; fi
  exit 1
fi
echo "Signed with: $IDENTITY"
echo "Built $APP"
