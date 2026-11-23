#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/build/scrcpy-cache"
VERSION="5.0.1"
PREFIX="scrcpy-macos-aarch64-v$VERSION"
BASE="https://github.com/Genymobile/scrcpy/releases/download/v$VERSION"

if [ "$#" -ne 2 ] || [[ "$1" != bundle && "$1" != sources ]]; then
  echo "Usage: $0 bundle <DeskBridge.app> | sources <source archive>" >&2
  exit 2
fi

mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/.stage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

checksum() {
  printf '%s  %s\n' "$2" "$1" | shasum -a 256 --check --status
}

fetch() {
  local name="$1" url="$2" digest="$3"
  if ! checksum "$CACHE/$name" "$digest" 2>/dev/null; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --retry 2 --connect-timeout 15 --max-time 120 "$url" -o "$WORK/$name"
    if ! checksum "$WORK/$name" "$digest"; then
      echo "SHA-256 mismatch for $name" >&2
      exit 1
    fi
    mv -f "$WORK/$name" "$CACHE/$name"
  fi
}

if [ "$1" = bundle ]; then
  fetch "$PREFIX.tar.gz" "$BASE/$PREFIX.tar.gz" \
    33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b
  tar -xzf "$CACHE/$PREFIX.tar.gz" -C "$WORK" \
    "$PREFIX/scrcpy" "$PREFIX/scrcpy-server" "$PREFIX/scrcpy.png" "$PREFIX/disconnected.png" "$PREFIX/LICENSE"
  component="$2/Contents/Resources/scrcpy"
  mkdir -p "$2/Contents/Helpers" "$component/Licenses"
  install -m 755 "$WORK/$PREFIX/scrcpy" "$2/Contents/Helpers/scrcpy"
  cp "$WORK/$PREFIX/scrcpy-server" "$WORK/$PREFIX/scrcpy.png" "$WORK/$PREFIX/disconnected.png" "$component/"
  cp "$WORK/$PREFIX/LICENSE" "$component/Licenses/scrcpy.txt"
  cp "$ROOT"/mac/Resources/ScrcpyLicenses/*.txt "$component/Licenses/"
  exit
fi

# The library versions and checksums match the upstream release scripts at v5.0.1.
fetch "scrcpy-$VERSION.tar.gz" "https://codeload.github.com/Genymobile/scrcpy/tar.gz/refs/tags/v$VERSION" \
  a24b996ac23d0f674d3237c00b39a97829d8acbe9e1657a6c216fd51ea488ee5
fetch "scrcpy-server-v$VERSION" "$BASE/scrcpy-server-v$VERSION" \
  764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536
fetch sdl-3.4.18.tar.gz https://codeload.github.com/libsdl-org/SDL/tar.gz/refs/tags/release-3.4.18 \
  c4b08b950bd29d83caae0ab8d884298d27046a9d30700fb42841c50992665c90
fetch dav1d-1.5.4.tar.xz https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz \
 686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
fetch ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
  8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
fetch libusb-1.0.30.tar.gz https://codeload.github.com/libusb/libusb/tar.gz/refs/tags/v1.0.30 \
  2ae28adb0bb9558c86135c4e1c11b320b0805461e207a64a6e520a114094bf07
fetch zlib-1.3.2.tar.gz https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz \
  bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16

name="DeskBridge-scrcpy-$VERSION-sources"
mkdir "$WORK/$name"
cp "$CACHE/scrcpy-$VERSION.tar.gz" "$CACHE/scrcpy-server-v$VERSION" "$CACHE/sdl-3.4.18.tar.gz" \
  "$CACHE/dav1d-1.5.4.tar.xz" "$CACHE/ffmpeg-9.0.2.tar.xz" "$CACHE/libusb-1.0.30.tar.gz" \
  "$CACHE/zlib-1.3.2.tar.gz" "$WORK/$name/"
install -m 755 "$ROOT/scripts/rebuild_scrcpy_macos.sh" "$WORK/$name/rebuild.sh"
cp "$ROOT/docs/MAC_SCRCPY_SOURCES.md" "$WORK/$name/README.md"
tar -czf "$WORK/sources.tar.gz" -C "$WORK" "$name"
mv -f "$WORK/sources.tar.gz" "$2"
