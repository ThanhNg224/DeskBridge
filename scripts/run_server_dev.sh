#!/usr/bin/env bash
# Runs ServerMain on the device with a fresh socket name/token and prints the forwarded port.
# The Mac app does the same thing itself (ServerLauncher); this is for debugging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="deskbridge-$(openssl rand -hex 4)"
TOKEN="$(openssl rand -hex 16)"

"$ROOT/scripts/build_server.sh" >/dev/null
adb push "$ROOT/server/build/deskbridge-server.jar" /data/local/tmp/deskbridge-server.jar >/dev/null
PORT="$(adb forward tcp:0 "localabstract:$NAME")"
trap 'adb forward --remove "tcp:$PORT" >/dev/null 2>&1 || true' EXIT

echo "port=$PORT token=$TOKEN"
adb shell "CLASSPATH=/data/local/tmp/deskbridge-server.jar exec app_process / com.deskbridge.server.ServerMain $NAME $TOKEN"
