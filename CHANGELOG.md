# Changelog

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

Known limits: Vietnamese/IME text input, clipboard sync, multiple devices, other Android versions untested.
