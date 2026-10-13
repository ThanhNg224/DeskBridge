<p align="center"><img src="docs/logo.png" width="128" alt="DeskBridge logo"></p>

<h1 align="center">DeskBridge</h1>

<p align="center">
Use your Mac's mouse and keyboard on your Android phone or tablet.<br>
Push the pointer off the edge of the screen and it appears on the phone. Push it back and it returns.
</p>

<p align="center">
<a href="https://github.com/ThanhNg224/DeskBridge/releases/latest/download/DeskBridge.zip"><b>Download for Mac</b></a>
 ·
<a href="https://github.com/ThanhNg224/DeskBridge/releases/latest">All releases</a>
</p>

---

## What it does

- **One mouse and keyboard for both.** Click, scroll, drag and type on the phone without touching it.
- **Over a USB cable.** Nothing to install on the phone, no Wi-Fi, no account, nothing leaves your desk.
- **Fast.** Typically about 1 ms of delay, so it feels like a normal mouse.
- **Copy and paste shortcuts just work.** `Cmd+C`, `Cmd+V` and `Cmd+A` become their Android equivalents, and copied text follows the pointer: copy on the Mac, paste on the phone, and the other way round.
- **Right click goes Back**, like on a phone (you can switch it to a real right click).
- **Type Vietnamese** with your Mac's input method (Telex, VNI): compose the word on the Mac, it appears on the phone when you press space.
- **Always a way out.** Press **⌃⌥⌘⎋** (Control+Option+Command+Esc) to get the pointer back on the Mac instantly.

## What you need

- A Mac with Apple Silicon, macOS 14 or newer.
- An Android phone or tablet, Android 13 or newer, and a USB cable.
- Android's USB tools (`adb`). If you use [Homebrew](https://brew.sh): `brew install --cask android-platform-tools`.

## Get started

1. **Download** [DeskBridge.zip](https://github.com/ThanhNg224/DeskBridge/releases/latest/download/DeskBridge.zip), unzip it and drag **DeskBridge** to your Applications folder.
2. **Open it the first time.** The app is not yet notarized by Apple, so macOS blocks it once: open **System Settings > Privacy & Security**, scroll down and click **Open Anyway** next to DeskBridge. (Or run `xattr -dr com.apple.quarantine /Applications/DeskBridge.app` in Terminal.)
3. **Allow Accessibility.** DeskBridge asks for it so it can read your mouse and keyboard: **System Settings > Privacy & Security > Accessibility**, switch DeskBridge on.
4. **Prepare the phone.** Turn on *Developer options* (tap **Build number** seven times in *Settings > About phone*), then switch on **USB debugging**. Xiaomi/HyperOS phones also need **USB debugging (Security settings)**.
5. **Plug the phone in** and tap **Allow** on the phone when it asks to trust the computer.

The DeskBridge window shows what is still missing and turns green when everything is ready. Then move the pointer past the screen edge you picked (Settings lets you choose left, right, top or bottom) and it jumps to the phone.

## Questions

**The pointer does not cross.** Open DeskBridge: the checklist tells you which step is missing (Accessibility, `adb`, or the phone not authorized). Make sure the screen edge in Settings is the side where you move the mouse.

**Can I use it without a cable?** Not at the moment. USB is what keeps it fast and private.

**Is it safe?** The phone side is a small program started over `adb`; it only talks over the USB cable and every session uses a one-time token. Details in [the architecture notes](docs/ARCHITECTURE.md).

## Known limits

- **Typing with an input method** (Vietnamese Telex/VNI, ...): the word is composed on the Mac, where a small preview appears at the bottom of the screen, and goes to the phone when you commit it (space, punctuation). Words with accents reach the phone by pasting: the phone's clipboard is used for a moment and then put back (an image on the clipboard is lost), and Samsung may show its "Copied to clipboard" toast. Other input methods (Japanese, Chinese) are untested.
- **Clipboard:** text only (no images or files). It is shared when the pointer crosses, so something you copy by touching the phone while the pointer is on the Mac reaches the Mac the next time the pointer comes back from the phone. Samsung shows a "Copied to clipboard" toast when text arrives on the phone.
- **One phone at a time.** With several plugged in, DeskBridge lets you choose which one.
- **USB only.** No wireless mode.
- **Rotating the phone** while the pointer is on it takes effect the next time the pointer enters.
- **Locked phone:** the mouse wakes a sleeping screen but does not unlock it.
- **Bottom edge over the Dock:** the Mac pointer can flash for about a tenth of a second before it disappears, mostly when the DeskBridge window is on a second display. DeskBridge also comes to the front each time the pointer goes to the phone: it has to be the active app to hide the pointer.
- **Phones:** Android 13 and newer. Tested on a Samsung with Android 13, by hand on Android 10, and on Android 14, 15 and 16 emulators. Xiaomi/HyperOS and other vendor skins are untested.
- **Not notarized yet:** macOS asks you to approve the first launch (see *Get started*).

---

## For developers

DeskBridge is a Swift 6 menu bar app (`mac/`) plus a plain-Java server (`server/`) that the Mac starts on the phone through `adb shell app_process`. No APK, no Gradle, no Kotlin. Mouse and keyboard travel over an adb-forwarded abstract socket with a small binary protocol; the server injects them through Android's `InputManager` and draws its own pointer.

Start with **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** (decisions, protocol, security model, risks) and **[CLAUDE.md](CLAUDE.md)** (commands, rules and gotchas for people and AI agents).

### Build from source

Needs macOS 14+ on Apple Silicon, Xcode 16+ (Swift 6), JDK 17+, the Android SDK `build-tools` (`d8`) with any `platforms/android-*`, and `adb`.

```bash
scripts/setup_signing.sh   # once: a local signing identity, so macOS keeps the Accessibility grant across rebuilds
scripts/package_app.sh     # build/DeskBridge.app
```

### Test

```bash
scripts/check.sh                                                     # everything: lint, server tests, builds, Mac tests
scripts/test_server.sh                                               # server unit tests (pure Java)
cd mac && swift test                                                 # Mac unit tests
scripts/run_on_device.sh com.deskbridge.server.PointerSpike          # injection diagnostic, look at the phone
cd mac && DESKBRIDGE_DEVICE=1 swift test --filter DeviceSmokeTests   # end to end on a plugged-in phone
scripts/device_matrix.sh                                             # Android 14, 15, 16 emulators
```

### Release

`scripts/release.sh` builds `build/DeskBridge.zip`, the file behind the download link (`gh release upload vX.Y.Z build/DeskBridge.zip --clobber`). With a paid Apple Developer account it also signs, notarizes and staples, so users can skip the "Open Anyway" step:

```bash
DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=deskbridge scripts/release.sh
```

(The one-time `notarytool store-credentials` step is described at the top of the script.)

### Verified on

Android 13 (Samsung, real device), Android 10 (by hand), Android 14, 15 and 16 (emulators). Other phones and vendor skins are untested; reports are welcome.
