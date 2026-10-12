# DeskBridge

Share a Mac mouse/keyboard with an Android device over USB/ADB. Mac menu-bar app (Swift 6) + plain-Java server run on the phone via `app_process`.

Read first: `docs/ARCHITECTURE.md` (decisions, protocol, security) and `docs/IMPLEMENTATION_PLAN.md` (ordered tasks with code).

## Verify

- `scripts/check.sh` runs everything (shellcheck, swiftformat lint, server tests, jar build, `swift build`, `swift test`) and prints one line per stage. Use it as the default verification; run it through the `runner` agent.
- Individual: `scripts/test_server.sh`, `scripts/build_server.sh`, `cd mac && swift test`.
- Device-only (needs an authorized phone): `scripts/run_on_device.sh com.deskbridge.server.PointerSpike`, `DESKBRIDGE_DEVICE=1 swift test --filter DeviceSmokeTests`. Look at the result yourself with `adb exec-out screencap -p > shot.png` and read the image.
- Format: `swiftformat mac` (config in `.swiftformat`). It strips `self.` that closures/logger interpolations need: compute a local first.
- App logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "com.deskbridge.app"' --style compact` (note: plain `log` is shadowed in zsh).

## Rules

- Android does not draw or move its system pointer for injected events (verified on Android 13). The server draws its own arrow with `CursorOverlay` (shell-owned `SurfaceControl` layer). Re-run `PointerSpike` on any new device/Android version; `hold` and `click X Y` modes exist for screenshots (`adb exec-out screencap -p`).
- The protocol is a contract: `PacketType.java`/`ProtocolDecoder.java` and `Packets.swift` must match ARCHITECTURE §4 byte for byte. Actions: `0 = DOWN`, `1 = UP`. Change both sides and both test suites together.
- Server must never listen on a TCP port. Abstract unix socket, random name, per-session token (ARCHITECTURE §5).
- Fail fast: no silent fallbacks around reflection or injection; surface the error to the Mac.
- Server code is plain Java compiled with `--release 11` and `d8` (no Gradle, no Kotlin, no dependencies).

## Gotchas already hit

- `SurfaceControl.Transaction` has `setVisibility`, not `show/hide`, in the public stubs. `MotionEvent.setActionButton` is `@hide`: call it by reflection (not in `android.jar`).
- Event tap callback must return `Unmanaged.passUnretained(event)` (not `passRetained`) and respond to `tapDisabledByTimeout`; keep the callback cheap and off the main thread.
- While Android has control the Mac cursor is frozen: use `mouseEventDeltaX/Y`, never `event.location`, for movement.
- Right click maps to `KEYCODE_BACK` on the Mac side; Android does not do it for injected secondary clicks.
- NWConnection needs `noDelay = true`; `.waiting` means connection refused (retry), not "still connecting".
- Accessibility/Input Monitoring grants attach to the signed `.app`; ad-hoc signing resets them every build.
