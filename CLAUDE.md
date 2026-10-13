# DeskBridge

Share a Mac mouse/keyboard with an Android device over USB/ADB. Mac menu-bar app (Swift 6) + plain-Java server run on the phone via `app_process`.

Read first: `docs/ARCHITECTURE.md` (decisions, protocol, security).

## Verify

- `scripts/check.sh` runs everything (shellcheck, swiftformat lint, server tests, jar build, `swift build`, `swift test`) and prints one line per stage. Use it as the default verification; run it through the `runner` agent.
- Release zip: `scripts/release.sh` (ad-hoc signed; `DEVELOPER_ID` + `NOTARY_PROFILE` env vars add signing and notarization), then `gh release upload vX.Y.Z build/DeskBridge.zip --clobber`.
- Individual: `scripts/test_server.sh`, `scripts/build_server.sh`, `cd mac && swift test`.
- `scripts/device_matrix.sh` boots the API 34/35/36 emulators and checks each (`MATRIX_SWIFT=1` adds the Swift smoke tests per emulator). `ANDROID_SERIAL=<serial>` selects the device for the smoke tests (default: first ready device); `DESKBRIDGE_MAX_P95_MS` overrides the ping p95 limit (25).
- Device-only (needs an authorized phone): `scripts/run_on_device.sh com.deskbridge.server.PointerSpike`, `DESKBRIDGE_DEVICE=1 swift test --filter DeviceSmokeTests`. Look at the result yourself with `adb exec-out screencap -p > shot.png` and read the image.
- Format: `swiftformat mac` (config in `.swiftformat`). It strips `self.` that closures/logger interpolations need: compute a local first.
- App logs: `/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.deskbridge.app"' --style compact` (note: plain `log` is shadowed in zsh).

## Rules

- Android does not draw or move its system pointer for injected events (verified on Android 13). The server draws its own arrow with `CursorOverlay` (shell-owned `SurfaceControl` layer). Re-run `PointerSpike` on any new device/Android version; `hold` and `click X Y` modes exist for screenshots (`adb exec-out screencap -p`).
- The protocol is a contract: `PacketType.java`/`ProtocolDecoder.java` and `Packets.swift` must match ARCHITECTURE §4 byte for byte. Actions: `0 = DOWN`, `1 = UP`. Change both sides and both test suites together.
- Server must never listen on a TCP port. Abstract unix socket, random name, per-session token (ARCHITECTURE §5).
- Fail fast: no silent fallbacks around reflection or injection; surface the error to the Mac.
- Server code is plain Java compiled with `--release 11` and `d8` (no Gradle, no Kotlin, no dependencies).

## Gotchas already hit

- The cursor sprite must not cover the injected click point: Android 12+ drops touches under an untrusted overlay layer ("Untrusted touch due to occlusion by /2000", Samsung toast "isn't optimised for the latest version of Android"). `CursorOverlay` offsets the sprite 1 px; `cursorOverlayDoesNotBlockClicks` guards it.
- `SurfaceControl.Transaction` has `setVisibility`, not `show/hide`, in the public stubs. `MotionEvent.setActionButton` is `@hide`: call it by reflection (not in `android.jar`).
- Event tap callback must return `Unmanaged.passUnretained(event)` (not `passRetained`) and respond to `tapDisabledByTimeout`; keep the callback cheap and off the main thread.
- Edges are per display, never the bounding box of all displays (a tall portrait monitor next to a short one made the short one's bottom edge dead). Top/bottom only count on the main display. Cursor hiding: `CGDisplayHideCursor` from a background app is unreliable (the window server keeps the Dock in cursor control, other apps' floating panels win too, and it returns success anyway). `CursorShield` therefore activates the app, puts a 5% window above the Dock level and sets a transparent cursor image on it (Apple DTS forum thread 756199), then restores the previous app. Order in `RemoteCursor.engage`: hide at once, shield up (transparent cursor), warp off the hovered Dock icon and freeze at once (a user pushing down keeps sending real moves that would drag the cursor back onto the icon; the Dock is told the pointer left by one zero-delta move marked with `InputCapturer.syntheticMarker`, which the tap lets through). Do not reorder without testing the bottom edge over the Dock by hand: pause on a Dock icon, then push down fast. The shield's transparent cursor is sometimes not applied (seen after the Mac was idle); `RemoteCursor.verifyBlankCursor` checks `NSCursor.currentSystem` (16x16 = ours, the arrow is 28x40) and escalates the retries. A script that posts fast synthetic moves down onto a Dock icon reproduces both problems (screenshot with `screencapture -x -R`).
- While Android has control the Mac cursor is frozen: use `mouseEventDeltaX/Y`, never `event.location`, for movement.
- Text from a Mac input method (Vietnamese Telex, ...): the tap sees only raw key codes, and feeding synthetic `NSEvent`s to `inputContext.handleEvent` does not compose (tried). What works is letting real key events through the tap (`KeyRouting`, `InputCapturer.deliversKeyToMac`) to `ComposerView` (an `NSTextInputClient` in the shield window) when the selected input source is not a plain layout. Keys must only go through while the shield is the key window of the active app, or they land in another Mac app. On the phone, injected key events are not composed by Samsung Keyboard, `ACTION_MULTIPLE` is ignored by Samsung Notes, and `KEYCODE_PASTE` did not paste there but Ctrl+V does; `InputInjector.text` pastes accented text. Samsung shows a "Copied to clipboard" toast when the clip is set from Notes with its keyboard up. `TextSpike` (`run_on_device.sh com.deskbridge.server.TextSpike text|set|get WORD`) tries all this by hand.
- Right click maps to `KEYCODE_BACK` on the Mac side; Android does not do it for injected secondary clicks.
- NWConnection needs `noDelay = true`; `.waiting` means connection refused (retry), not "still connecting".
- Accessibility/Input Monitoring grants attach to the signed `.app`. `scripts/setup_signing.sh` creates the local identity "DeskBridge Dev" (once); `scripts/package_app.sh` uses it automatically (designated requirement: bundle id + cert hash), so grants survive rebuilds. Without it the build is ad-hoc signed with a bundle-id requirement.
