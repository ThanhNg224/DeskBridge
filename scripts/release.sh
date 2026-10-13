#!/usr/bin/env bash
# Builds the downloadable build/DeskBridge.zip (the asset behind the README's download link).
#
#   scripts/release.sh                      ad-hoc signed: works, but macOS asks the user to approve the first launch
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=deskbridge scripts/release.sh
#                                           signed, notarized and stapled: opens with a double click
#
# One-time notarization setup (needs the paid Apple Developer Program and a "Developer ID Application" certificate):
#   xcrun notarytool store-credentials deskbridge --apple-id <id> --team-id <TEAMID>   (asks for an app-specific password)
#
# Publish: gh release upload vX.Y.Z build/DeskBridge.zip --clobber
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DeskBridge.app"
ZIP="$ROOT/build/DeskBridge.zip"

CODESIGN_IDENTITY="${DEVELOPER_ID:--}" "$ROOT/scripts/package_app.sh"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${DEVELOPER_ID:-}" ] || { echo "NOTARY_PROFILE needs DEVELOPER_ID" >&2; exit 1; }
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP" # ditto keeps the signature and symlinks intact (zip does not)
echo "Built $ZIP"
