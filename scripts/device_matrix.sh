#!/usr/bin/env bash
# Boots each AVD headless (one at a time), runs the PointerSpike checks and prints one PASS|FAIL line per AVD.
# Usage: scripts/device_matrix.sh [avd ...]   (default: deskbridge-api34 deskbridge-api35 deskbridge-api36)
# Checks: server starts and holds the pointer, no "Untrusted touch" occlusion, a click opens the Phone app,
# the Back key (injected) leaves it. Screencaps go to build/matrix/. Only the emulator on PORT is touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PATH="$SDK/emulator:$SDK/platform-tools:$PATH"
PORT=5554
EMU="emulator-$PORT"
OUT="$ROOT/build/matrix"
mkdir -p "$OUT"

if [ "$#" -gt 0 ]; then AVDS=("$@"); else AVDS=(deskbridge-api34 deskbridge-api35 deskbridge-api36); fi

spike() { ANDROID_SERIAL="$EMU" "$ROOT/scripts/run_on_device.sh" com.deskbridge.server.PointerSpike "$@" 2>&1; }
top() { adb -s "$EMU" shell dumpsys activity activities | grep -m1 topResumedActivity; }

boot() {
    nohup emulator -avd "$1" -port "$PORT" -no-window -no-audio -no-snapshot -gpu swiftshader_indirect \
        > "$OUT/$1.emulator.log" 2>&1 &
    local _
    for _ in $(seq 1 120); do
        [ "$(adb -s "$EMU" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0
        sleep 4
    done
    return 1
}

shutdown() {
    adb -s "$EMU" emu kill >/dev/null 2>&1
    sleep 8
}

# Prints "reason" on failure, nothing on success.
check() {
    local avd="$1" api="$2" out
    local log="$OUT/$avd.log"
    : > "$log"
    adb -s "$EMU" shell input keyevent KEYCODE_WAKEUP
    adb -s "$EMU" shell wm dismiss-keyguard
    adb -s "$EMU" shell input keyevent KEYCODE_HOME
    sleep 2

    spike hold > "$OUT/$avd.hold.txt" &
    sleep 7
    adb -s "$EMU" exec-out screencap -p > "$OUT/$api.png"
    wait
    grep -q "holding pointer" "$OUT/$avd.hold.txt" || { echo "hold failed: $(grep -m1 -E 'Exception|Error' "$OUT/$avd.hold.txt")"; return; }

    # Phone icon centre from the UI hierarchy, so no device-specific coordinates.
    adb -s "$EMU" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    local bounds left top_ right bottom x y
    bounds="$(adb -s "$EMU" shell cat /sdcard/ui.xml | tr '>' '\n' | grep 'content-desc="Phone"' | head -1 \
        | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')"
    [ -n "$bounds" ] || { echo "no Phone icon on the home screen"; return; }
    read -r left top_ right bottom <<< "$bounds"
    x=$(((left + right) / 2))
    y=$(((top_ + bottom) / 2))

    adb -s "$EMU" logcat -c
    out="$(spike click "$x" "$y")"
    echo "$out" >> "$log"
    sleep 2
    local untrusted
    untrusted="$(adb -s "$EMU" logcat -d | grep -c 'Untrusted touch due to occlusion by /2000')"
    [ "$untrusted" = 0 ] || { echo "untrusted touch occlusion x$untrusted"; return; }
    top | grep -q dialer || { echo "click did not open the Phone app ($out)"; return; }

    spike key 4 >> "$log"
    sleep 2
    top | grep -q dialer && { echo "Back key did not leave the Phone app"; return; }
    return 0
}

STATUS=0
for AVD in "${AVDS[@]}"; do
    API="${AVD##*-}"
    if ! boot "$AVD"; then
        echo "FAIL $API emulator did not boot"
        STATUS=1
        shutdown
        continue
    fi
    REASON="$(check "$AVD" "$API")"
    if [ -n "$REASON" ]; then
        echo "FAIL $API $REASON"
        STATUS=1
    else
        echo "PASS $API arrow drawn (see build/matrix/$API.png), no untrusted touch, click and Back landed"
    fi
    shutdown
done
exit "$STATUS"
