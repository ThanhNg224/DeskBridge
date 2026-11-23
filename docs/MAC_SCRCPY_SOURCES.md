# Rebuilding the DeskBridge scrcpy helper

The DeskBridge macOS app includes the Genymobile scrcpy 5.0.1 Apple Silicon client and its matching Android server. This source archive includes the matching scrcpy source tree with the upstream build configuration, as well as the source for SDL 3.4.18, dav1d 1.5.4, FFmpeg 9.0.2, libusb 1.0.30 and zlib 1.3.2. The last version matches the Homebrew formula at the time of the upstream build.

The client is a standalone executable. You can rebuild it, including with modified versions of the libraries, and run the rebuilt client directly with the supplied Android server and your own ADB. No DeskBridge source or signing key is needed to run a relinked helper.

On Apple Silicon, install the Xcode Command Line Tools, then install the build tools with `brew install meson ninja cmake pkgconf autoconf automake libtool nasm`. Extract the source archive and run these commands from its top-level directory. The output directory must exist.

```sh
./rebuild.sh "$PWD/scrcpy"
ADB=/path/to/adb SCRCPY_SERVER_PATH="$PWD/scrcpy-server-v5.0.1" ./scrcpy
```

The rebuild uses the upstream macOS static build configuration, with a locally built zlib in place of the Homebrew zlib prefix. A newer compiler or SDK can change the resulting bytes.

To rebuild with a modified library, replace its archive while keeping the filename and top-level directory expected by the build. For SDL, dav1d, FFmpeg or libusb, extract `scrcpy-5.0.1.tar.gz` and update `SHA256SUM` in that library's `app/deps` script to match the replacement archive. Repack the edited scrcpy tree before running `rebuild.sh` again.

```sh
tar -czf scrcpy-5.0.1.tar.gz scrcpy-5.0.1
```

For zlib, replace `zlib-1.3.2.tar.gz` with an archive containing the modified `zlib-1.3.2` directory, then run `rebuild.sh` again.

License texts are in the component archives and in the DeskBridge bundle under `Contents/Resources/scrcpy/Licenses`. FFmpeg and libusb are distributed under the LGPL. The upstream source histories and exact dependency pins are in the scrcpy source archive.
