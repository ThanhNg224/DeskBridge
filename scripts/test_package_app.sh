#!/usr/bin/env bash
# Exercise package installation and signing failures without touching the real application.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/mac/Resources/en.lproj" "$TEST_ROOT/server/build" "$TEST_ROOT/build/DeskBridge.app" "$TEST_ROOT/bin"
cp "$ROOT/scripts/package_app.sh" "$TEST_ROOT/scripts/package_app.sh"
printf old > "$TEST_ROOT/build/DeskBridge.app/sentinel"
printf 1.0 > "$TEST_ROOT/VERSION"
printf icon > "$TEST_ROOT/mac/Resources/AppIcon.icns"
printf license > "$TEST_ROOT/mac/Resources/ThirdPartyNotices.txt"
printf strings > "$TEST_ROOT/mac/Resources/en.lproj/Localizable.strings"
printf executable > "$TEST_ROOT/bin/DeskBridge"
mkdir -p "$TEST_ROOT/bin/ZIPFoundation_ZIPFoundation.bundle/Contents/Resources"
printf privacy > "$TEST_ROOT/bin/ZIPFoundation_ZIPFoundation.bundle/Contents/Resources/PrivacyInfo.xcprivacy"
cat > "$TEST_ROOT/scripts/build_server.sh" <<'STUB'
#!/usr/bin/env bash
printf jar > "$(dirname "$0")/../server/build/deskbridge-server.jar"
STUB
cat > "$TEST_ROOT/bin/swift" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" --show-bin-path "* ]]; then printf '%s\n' "$TEST_ROOT/bin"; fi
STUB
cat > "$TEST_ROOT/bin/security" <<'STUB'
#!/usr/bin/env bash
case "${TEST_IDENTITIES:-one}" in
  none) exit 0 ;;
  multiple) printf '%s\n' '  1) 111 "DeskBridge Dev"' '  2) 222 "DeskBridge Dev"' ;;
  *) printf '%s\n' '  1) 111 "DeskBridge Dev" (CSSMERR_TP_NOT_TRUSTED)' '  1) 111 "DeskBridge Dev"' ;;
esac
STUB
cat > "$TEST_ROOT/bin/codesign" <<'STUB'
#!/usr/bin/env bash
if [ "${TEST_SIGN_FAIL:-0}" = 1 ] && [ "$1" = "--force" ]; then exit 1; fi
printf '%s\n' "$*" >> "$TEST_ROOT/codesign.log"
STUB
chmod +x "$TEST_ROOT/scripts/build_server.sh" "$TEST_ROOT/bin/swift" "$TEST_ROOT/bin/security" "$TEST_ROOT/bin/codesign"
export TEST_ROOT PATH="$TEST_ROOT/bin:$PATH"
unset CODESIGN_IDENTITY

for TEST_IDENTITIES in none multiple; do
  export TEST_IDENTITIES
  if "$TEST_ROOT/scripts/package_app.sh" >/dev/null 2>&1; then echo "Unexpected signing identity acceptance" >&2; exit 1; fi
  [ "$(<"$TEST_ROOT/build/DeskBridge.app/sentinel")" = old ]
done
export TEST_IDENTITIES=one TEST_SIGN_FAIL=1
if "$TEST_ROOT/scripts/package_app.sh" >/dev/null 2>&1; then echo "Unexpected signing success" >&2; exit 1; fi
[ "$(<"$TEST_ROOT/build/DeskBridge.app/sentinel")" = old ]
unset TEST_SIGN_FAIL
"$TEST_ROOT/scripts/package_app.sh" >/dev/null
grep -q -- '--force --sign 111' "$TEST_ROOT/codesign.log"
[ -f "$TEST_ROOT/build/DeskBridge.app/Contents/MacOS/DeskBridge" ]
[ -f "$TEST_ROOT/build/DeskBridge.app/Contents/Resources/ThirdPartyNotices.txt" ]
[ -f "$TEST_ROOT/build/DeskBridge.app/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle/Contents/Resources/PrivacyInfo.xcprivacy" ]
[ ! -e "$TEST_ROOT/build/DeskBridge.app/sentinel" ]
DESKBRIDGE_APP_OUTPUT="$TEST_ROOT/build/release/DeskBridge.app" CODESIGN_IDENTITY=- "$TEST_ROOT/scripts/package_app.sh" >/dev/null
[ -f "$TEST_ROOT/build/release/DeskBridge.app/Contents/MacOS/DeskBridge" ]
[ -f "$TEST_ROOT/build/DeskBridge.app/Contents/MacOS/DeskBridge" ]
grep -q -- '--force --sign - ' "$TEST_ROOT/codesign.log"
echo "OK package signing and rollback"
