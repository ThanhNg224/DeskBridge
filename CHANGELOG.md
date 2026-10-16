# Changelog

## 1.1.6 (2026-10-16)

- Added in-app Switch to Wi-Fi, manual IPv4/port connection, and Disconnect Wi-Fi actions, with USB/Wi-Fi indicators in the phone selector.
- Aligned the Wi-Fi form, added input validation and English/Vietnamese errors, and prevented overlapping connection actions. Device selection now handles stale preferences and mDNS wireless endpoints; the phone list updates while paused.
- Switching to Wi-Fi uses the phone's wlan0 address. A real Samsung Android 13 session stayed connected after USB was unplugged; Wi-Fi-only movement/exit verification passed.
- Documented the difference between unencrypted legacy ADB TCP/IP and paired Wireless Debugging with TLS. Pairing is still performed outside DeskBridge.

Known limit: measured Wi-Fi PING/PONG p95 was 34.06–41.10 ms on the tested network, exceeding the unchanged 25 ms gate. Transport RTT is not full input latency. See [docs/WIRELESS_VERIFICATION.md](docs/WIRELESS_VERIFICATION.md) for details.

## 1.1.5 (2026-10-13)

- Fixed a CPU burn that started whenever a session ended (phone unplugged, `adb` restarted, app switched off and on): the reader of the phone server's error output kept firing on the closed pipe and used a whole core until DeskBridge was quit. Present since 1.0.0.
- Phones are now detected through the adb server's own change notifications (`host:track-devices` over its TCP port, no child process) instead of polling: plugging or unplugging is noticed at once, and an idle app wakes up only for its 2 s ping. The old polling stays as a slow safety net (30 s, 60 s while connected) and as the retry clock after a failed start; it falls back to the faster intervals if the watcher cannot reach adb.

## 1.1.4 (2026-10-13)

- Less polling: while connected the Mac checks for phones every 10 s (was 2 s), 4 s with no phone plugged in, 5 s while paused. Plugging, unplugging, switching on and coming back from System Settings are still picked up at once. Idle wake-ups dropped from about 0.5 to about 0.1 per second.
- Typing with a Mac input method (Vietnamese Telex/VNI, ...): while one is selected, letters, digits and punctuation go to an invisible text field in the shield window, macOS composes the word there (a preview label shows it at the bottom of the screen) and the committed text goes to the phone in a new `TEXT` packet. ASCII is typed as key presses, accented text is pasted (clipboard set, Ctrl+V, previous text clip restored after 200 ms; Samsung shows its "Copied to clipboard" toast for each such word, and the clip description flags that should hide it have no effect there). Cmd/Ctrl shortcuts, the release chord and keys outside a word still go straight to the phone, and nothing is routed to the Mac unless the shield window really is the key window.
- Shared clipboard (text): what you copied on the Mac is on the phone when the pointer crosses over, and what you copied on the phone is on the Mac when it comes back. Off switch in Settings. Nothing is polled (the clipboard is looked at once per hand-over), copies marked concealed by password managers are skipped, texts over 1 MiB are not sent, contents are never logged. Samsung shows its "Copied to clipboard" toast when the Mac's text arrives.

## 1.1.3 (2026-10-13)

- Bottom edge over the Dock: the Dock icon label no longer stays after the pointer moves to Android when the mouse is pushed down fast (the cursor was dragged back onto the icon before it froze).
- The transparent cursor of the shield is verified after every hand-over and re-applied if the arrow is still showing (it was sometimes not applied after the Mac had been idle for a while).
- The check runs every 30 ms and the cursor is re-applied right at the freeze: with another app in front the arrow is gone after about 165 ms instead of 390 ms.
- Logs: one line per hand-over (`cursor frozen at ..., blank after N ms`), with a notice when a retry was needed and an error if the arrow stayed.
- Fixed a Swift concurrency warning in `RemoteCursor`.

Known limits: input methods (Vietnamese/IME) are not supported; one phone at a time; USB only; rotating the phone during a visit applies at the next visit; the mouse wakes a sleeping screen but does not unlock it; at the bottom edge over the Dock the pointer can flash for about 0.1 s (more noticeable with the DeskBridge window on a second display) and DeskBridge comes to the front on each hand-over; Xiaomi/HyperOS and other vendor skins untested; the download is not notarized (first launch needs Open Anyway).

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
