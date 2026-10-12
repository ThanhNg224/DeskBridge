#!/usr/bin/env bash
# Usage: scripts/run_on_device.sh <MainClass> [args...]   (honors ANDROID_SERIAL)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAR="$ROOT/server/build/deskbridge-server.jar"
CLASS="${1:?usage: run_on_device.sh <MainClass> [args...]}"
shift

"$ROOT/scripts/build_server.sh" >/dev/null
adb push "$JAR" /data/local/tmp/deskbridge-server.jar >/dev/null
adb shell "CLASSPATH=/data/local/tmp/deskbridge-server.jar exec app_process / $CLASS $*"
