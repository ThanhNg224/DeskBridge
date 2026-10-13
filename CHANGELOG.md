# Changelog

## Unreleased

- Bottom edge over the Dock: the Dock icon label no longer stays after the pointer moves to Android when the mouse is pushed down fast (the cursor was dragged back onto the icon before it froze).
- The transparent cursor of the shield is verified after every hand-over and re-applied if the arrow is still showing (it was sometimes not applied after the Mac had been idle for a while).
- The check runs every 30 ms and the cursor is re-applied right at the freeze: with another app in front the arrow is gone after about 165 ms instead of 390 ms.
- Logs: one line per hand-over (`cursor frozen at ..., blank after N ms`), with a notice when a retry was needed and an error if the arrow stayed.
- Fixed a Swift concurrency warning in `RemoteCursor`.

## 1.1.2 (2026-10-13)

- The mouse now wakes a phone whose screen is off (injected events do not wake it by themselves, so the server sends a wake key first). Leaving the phone never wakes it.
- The Settings window can be resized (400 to 700 pt wide); the header stays on top and the options scroll.

## 1.1.1 (2026-10-13)

- Settings window shows the live status again: coloured dot, status text, on/off switch and the release shortcut.
- The status text reserves two lines, so nothing below it jumps when the message gets longer or shorter.
- Downloadable `DeskBridge.zip` on the release page; `scripts/release.sh` builds it (and signs and notarizes when a Developer ID is available).
- README rewritten for everyday users; developer notes moved to the end.

## 1.1.0 (2026-10-13)

- Android 14, 15 and 16: input injection fixed (Android 14 crashed the server at startup); verified on emulators.
- Held keys are released on the phone when control goes back to the Mac.
- Pointer sprite scales from the short display side.
- Menu bar popover + Settings window, live setup checklist, English and Vietnamese, choice between several phones, Dock icon option, growing retry back-off.
- Edges and displays are re-read as soon as displays or the edge setting change.
- Internals: `DeviceSession` split into small tested units; server `Session` extracted and tested; device and emulator test tooling (`scripts/device_matrix.sh`).

## 1.0.0 (2026-10-13)

First stable release: Mac (Apple Silicon) shares its mouse and keyboard with an Android device over USB, no APK on the phone.

- Plain-Java server started with `app_process` (shell UID); abstract-socket transport with a per-session token, never exposed to the network.
- Pointer drawn by the server (Android does not draw its system pointer for injected events); clicks, drag, scroll, Back via right click.
- All four screen edges; top/bottom follow the main display; per-display edge detection for multi-monitor setups; armed exit so jitter does not hand control back.
- Mac cursor hidden reliably while Android has control (foreground shield window with a transparent cursor, Dock hover cleared).
- Keyboard: full keycode table, Cmd as Ctrl or Meta.
- Window + menu bar app: enable switch, pointer/scroll speed, invert scroll, launch at login, state-aware menu bar icon.
- Fail-safes: release chord ⌃⌥⌘⎋, auto-release on disconnect or 6 s silence.
- Verified on Android 13 (Samsung Galaxy Note10 Lite). adb round trip p50 ≈ 0.8 ms.

Known limits: Vietnamese/IME text input, clipboard sync, controlling several phones at once, rotating the phone while the pointer is on it.
