#!/usr/bin/env bash
# javac (against the SDK android.jar) -> d8 -> deskbridge-server.jar (zip with classes.dex).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"

ANDROID_JAR="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1 || true)"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
[ -f "$ANDROID_JAR" ] || { echo "No platforms/android-*/android.jar under $SDK (set ANDROID_HOME)" >&2; exit 1; }
[ -x "$BUILD_TOOLS/d8" ] || { echo "No build-tools/*/d8 under $SDK (set ANDROID_HOME)" >&2; exit 1; }

OUT="$ROOT/server/build"
rm -rf "$OUT/classes" "$OUT/dex" "$OUT/classes.jar" "$OUT/deskbridge-server.jar"
mkdir -p "$OUT/classes" "$OUT/dex"

find "$ROOT/server/src/main" -name '*.java' > "$OUT/sources.txt"
javac --release 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$OUT/classes" @"$OUT/sources.txt"
jar cf "$OUT/classes.jar" -C "$OUT/classes" .

"$BUILD_TOOLS/d8" --release --min-api 26 --lib "$ANDROID_JAR" --output "$OUT/dex" "$OUT/classes.jar"
(cd "$OUT/dex" && zip -q "$OUT/deskbridge-server.jar" classes.dex)

echo "Built $OUT/deskbridge-server.jar"
