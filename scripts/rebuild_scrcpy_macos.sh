#!/usr/bin/env bash
# Also shipped as rebuild.sh alongside the exact upstream source archives.
set -euo pipefail

if [ "$#" -ne 1 ] || [ "$(uname -m)" != arm64 ]; then
  echo "Usage on an Apple Silicon Mac: $0 <output executable>" >&2
  exit 2
fi

SOURCES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MACOSX_DEPLOYMENT_TARGET=11.0

tar -xzf "$SOURCES/scrcpy-5.0.1.tar.gz" -C "$WORK"
tar -xzf "$SOURCES/zlib-1.3.2.tar.gz" -C "$WORK"
PROJECT="$WORK/scrcpy-5.0.1"
DEPS="$PROJECT/app/deps/work/install/macos-native-static"
mkdir -p "$PROJECT/app/deps/work/sources"
cp "$SOURCES/sdl-3.4.18.tar.gz" "$SOURCES/dav1d-1.5.4.tar.xz" "$SOURCES/ffmpeg-9.0.2.tar.xz" \
  "$SOURCES/libusb-1.0.30.tar.gz" "$PROJECT/app/deps/work/sources/"

(
  cd "$WORK/zlib-1.3.2"
  ./configure --static --prefix="$DEPS"
  make -j"$(getconf _NPROCESSORS_ONLN)"
  make install
)

cd "$PROJECT"
# The dependency prefix now contains the pinned zlib. Avoid adding the host's Homebrew zlib.
sed -i '' 's|export PKG_CONFIG_PATH="/opt/homebrew/opt/zlib/lib/pkgconfig"|export PKG_CONFIG_PATH=|' app/deps/ffmpeg.sh
app/deps/sdl.sh macos native static
app/deps/dav1d.sh macos native static
app/deps/ffmpeg.sh macos native static
app/deps/libusb.sh macos native static

unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
meson setup "$WORK/client" -Dc_args="-I$DEPS/include" -Dc_link_args="-L$DEPS/lib" \
  --buildtype=release --strip -Db_lto=true -Dcompile_server=false \
  -Dprebuilt_server="$SOURCES/scrcpy-server-v5.0.1" -Dportable=true -Dstatic=true
ninja -C "$WORK/client"
install -m 755 "$WORK/client/app/scrcpy" "$OUTPUT"
