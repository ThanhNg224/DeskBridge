#!/usr/bin/env bash
# Compiles and runs the pure-Java unit tests (no Android SDK needed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/server/build/test-classes"
rm -rf "$OUT" && mkdir -p "$OUT"

javac --release 11 -d "$OUT" \
  "$ROOT"/server/src/main/java/com/deskbridge/server/protocol/*.java \
  "$ROOT"/server/src/main/java/com/deskbridge/server/PointerState.java \
  "$ROOT"/server/src/test/java/com/deskbridge/server/Tests.java

java -ea -cp "$OUT" com.deskbridge.server.Tests
