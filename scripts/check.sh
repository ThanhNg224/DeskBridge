#!/usr/bin/env bash
# One command to verify the repo: lint, server tests, jar build, Mac build + tests.
# Prints one line per stage; on failure prints the tail of that stage's log and exits 1.
# Stages whose inputs do not exist yet are skipped (the repo is built up task by task).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

stage() { # stage <name> <required path> <command...>
  local name="$1" required="$2"
  shift 2
  if [ ! -e "$required" ]; then
    echo "SKIP $name ($required not present yet)"
    return 0
  fi
  if "$@" >"$LOG" 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name"
    tail -n 40 "$LOG"
    exit 1
  fi
}

# xcbeautify keeps output short but can drop the compiler diagnostic, so append raw "error:" lines.
mac_swift() { # mac_swift build|test
  local raw="$LOG.raw" status
  swift "$1" --package-path mac 2>&1 | tee "$raw" | xcbeautify --quiet
  status="${PIPESTATUS[0]}"
  if [ "$status" -ne 0 ]; then grep -E "error:" "$raw" | head -20; fi
  rm -f "$raw"
  return "$status"
}
mac_build() { mac_swift build; }
mac_test() { mac_swift test; }

shopt -s nullglob
scripts=(scripts/*.sh)
shopt -u nullglob

stage "shellcheck"        "scripts"                         shellcheck -S warning "${scripts[@]}"
stage "package tests"    "scripts/test_package_app.sh"     scripts/test_package_app.sh
stage "swiftformat"       "mac/Package.swift"               swiftformat --lint mac
stage "strings"          "mac/Resources/vi.lproj"          plutil -lint mac/Resources/vi.lproj/Localizable.strings
stage "server tests"      "scripts/test_server.sh"          scripts/test_server.sh
stage "server jar"        "scripts/build_server.sh"         scripts/build_server.sh
stage "mac build"         "mac/Package.swift"               mac_build
stage "mac tests"         "mac/Package.swift"               mac_test

echo "ALL OK"
