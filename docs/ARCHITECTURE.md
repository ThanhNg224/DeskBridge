# DeskBridge System Architecture

## 1. Overview & Vision

The permanent `main` branch is the source of truth for the completed macOS ARM64 host. The permanent `windows` branch develops an independent Windows 11 x64 host in `windows/`, using .NET 10/WPF and Win32 adapters. It reuses the Java server and protocol v1 without sharing host runtime code. Automated Windows tests and packaging have passed CI; interactive Windows/Android acceptance remains pending. See [the Windows guide](../windows/README.md) and [acceptance record](WINDOWS_ACCEPTANCE.md). The macOS subsystem notes below are inherited reference material; original “Mac” directions in the protocol table apply to either host. Shared server/protocol fixes must be selectively ported and verified on each branch; the whole Windows branch is not merged into `main`.

**DeskBridge** shares one Mac mouse and keyboard with a physical **Android** phone/tablet over a USB cable or Wi-Fi ADB (similar to DeskDock, Synergy, or Logitech Flow).

When the Mac cursor pushes through the configured screen edge (left, right, top or bottom), control moves to the Android device. The cursor pushing back through the same edge returns control to the Mac. Keystrokes go to whichever device currently has control.

```
 +------------------------+                     +--------------------------+
 |      macOS (Host)      |                     |     Android (Target)     |
 |                        |                     |                          |
 |  CGEventTap thread     |                     |  deskbridge-server       |
 |        |               |                     |  (app_process, UID 2000) |
 |  DeviceSession         |   USB/Wi-Fi adb     |        ^                 |
 |  (state machine)       |   forward           |  LocalServerSocket       |
 |        |               |                     |  "deskbridge-<random>"   |
 |  Connection (NWConn)---+--127.0.0.1:<port>---+--> abstract unix socket   |
 |                        |   (adb allocates)   |        |                 |
 +------------------------+                     |  InputInjector           |
                                                |  (InputManager)          |
                                                +--------------------------+
```

---

## 2. Core Decisions & Trade-Offs

| Component | Selected Strategy | Rationale & Trade-offs |
| :--- | :--- | :--- |
| **Android server** | Standalone DEX jar run via `app_process` as shell UID (2000) | No APK install; shell holds `INJECT_EVENTS`. Needs USB debugging. Plain Java (no Kotlin stdlib) for fast start. **One server process per session**: it exits when the host disconnects, so there are no stale daemons. |
| **Input injection** | `InputManager.injectInputEvent` via reflection (absolute hover/click/scroll/keys) + a **server-drawn cursor** (`SurfaceControl` overlay) | Verified on a Galaxy Note10 Lite (Android 13): injected events do **not** move or draw Android's system pointer (its sprite layer stays hidden at its old position), but they act exactly (a click opens the app under it). A shell-owned `SurfaceControl` layer can be drawn above everything, so the server paints its own arrow and keeps it in sync with the injected position: exact tracking, no pointer acceleration drift, no `/dev/uhid` dependency. Trade-off: the arrow does not change shape (text/hand), and layer/hidden-API behavior must be re-checked per Android version with `PointerSpike`. Fallback if a device blocks the layer: UHID relative mouse. |
| **Mouse model** | Relative deltas from the Mac, pointer position owned by the server | The Mac cursor is frozen while Android has control, so absolute Mac coordinates are meaningless. Deltas are coalesced under backpressure (`MoveCoalescer`). Pointer speed is a Mac-side multiplier (Mac points to Android pixels). |
| **Transition** | Mac sends `ENTER{edge, along}`, server owns the pointer and sends `EXIT{along}` when pushed back through the entry edge | `along` is the normalized position along the shared edge, so the cursor lines up on both sides. All four edges are supported (Android left/right/above/below the Mac). |
| **Keyboard** | Full Mac virtual keycode → Android keycode table; unmapped keys are dropped; Cmd/Ctrl → `META_CTRL`; composed text uses `TEXT` | Shortcuts like Cmd+C work. Vietnamese input uses the Mac input method in a focused composer; committed accented text is pasted by the Android server with the previous text clipboard restored. Other input methods remain unverified. |
| **Right click** | Mac sends `KEYCODE_BACK` by default (toggle: real secondary button) | scrcpy does the same; the Android framework does not turn an injected secondary click into Back. |
| **Transport** | `adb forward tcp:0 localabstract:<random>` + per-session random token | adb allocates a free local port (multi-device safe). Abstract socket, not a TCP port on the phone, so nothing is exposed to the Wi-Fi network. See §5. |
| **Mac concurrency** | Tap callback on a dedicated thread; all session state on one serial `DispatchQueue`; only the "remote?" flag is shared (unfair lock) | Keeps the tap callback fast (macOS disables slow taps). |

---

## 3. Subsystem Breakdown

### 3.1 macOS (`mac/`, SwiftPM)

**Layout.** `DeskBridgeCore` is a library (unit-testable, no UI); `DeskBridge` is the app target.

```
DeskBridgeCore/
  Protocol/    Packets            wire format: encoder + incremental parser (matches the server byte for byte)
  Network/     ADBBridge, ServerLauncher, Connection (NWConnection, TCP_NODELAY)
  Input/       InputCapturer (event tap), RemoteInput (event -> packet, pure), KeyMapper, MoveCoalescer
  Display/     EdgeDetector (per-display edges, pure), Displays (display/window layout reads)
  Cursor/      RemoteCursor (park, swallow, freeze, hide, give back), CursorShield, ParkingPoint, WarpFilter
  Session/     DeviceSession (state machine + launch/connect/heartbeat), SessionEndReason, Backoff
  Discovery/   DevicePicker (which phone to use, pure)
  Config/      Settings (persisted), ServerJar
DeskBridge/
  AppModel (observable state, discovery loop), StatusText (user-facing text), SetupState
  Views/       MenuBarView (popover), SettingsView, SetupChecklist
  System/      Permissions, LoginItem, SettingsWindow
  AppDelegate, BrandIcon
```

Pure units (everything marked "pure") have unit tests; the session itself and the cursor choreography are covered by the device smoke tests and by manual checks.

- **Event tap:** `CGEvent.tapCreate` at `.cghidEventTap`, active filter. Captures mouse move/drag (all buttons), buttons, scroll, key down/up. In local mode events pass through; in remote mode they are swallowed. Re-enables itself on `tapDisabledByTimeout`.
- **Edges:** computed per display (`EdgeDetector`): an edge counts only where no other display sits right behind it. Top and bottom only count on the **main display**, so a tall or rotated secondary display never blocks the way. Left and right use every exposed edge. Control returns to the display it left from. Edges are rebuilt when displays change or the edge setting changes, and never while Android has control.
- **Remote mode (`RemoteCursor`)**, in this order: hide the cursor at once (so the jump below is not visible); move the cursor off whatever it hovers while events still pass (so the Dock clears its icon label); start swallowing; cover the display with a near-invisible foreground `CursorShield` window above the Dock level that shows a transparent cursor; warp again under it; freeze (`CGAssociateMouseAndMouseCursorPosition(false)`) and hide. Mouse input comes from `mouseEventDeltaX/Y`. After each warp, moves of 60 px or more are ignored for 0.3 s (smaller moves still reach Android). Background-app cursor hiding alone is unreliable (see CLAUDE.md).
- **Fail-safes:** release chord **⌃⌥⌘⎋**; control returns to the Mac automatically on disconnect, server exit, or 6 s without a packet.
- **Device lifecycle:** poll `adb devices -l` while no session is active (2 s, with a growing back-off after repeated failed starts: 2, 4, 8 ... 30 s); push jar, `forward`, spawn server, connect with retry until the server listens (up to 8 s). Several ready phones: the user picks one in Settings.
- **UI:** a menu bar popover (status, enable switch, Settings, Quit) plus a Settings window with a live setup checklist (Accessibility, adb, phone). The Dock icon is on by default and can be turned off. English and Vietnamese (`mac/Resources/vi.lproj`, English text is the key).
- **Packaging:** `scripts/package_app.sh` builds `DeskBridge.app` (version from `VERSION`, jar and localizations in Resources, codesigned) because Accessibility/Input Monitoring permissions attach to a signed bundle. `scripts/setup_signing.sh` creates the stable local identity.

### 3.2 Android server (`server/`, plain Java, no Gradle)
- Built with `javac --release 11` against the SDK `android.jar`, then `d8 --min-api 26`, zipped as `deskbridge-server.jar`.
- Entry: `app_process / com.deskbridge.server.ServerMain <socketName> <token>`.
- Pure-Java, unit-tested logic: `ProtocolDecoder`, `PointerState` (position, clamping, edge exit).
- Android-bound: `InputInjector`, `CursorOverlay` (arrow drawn into a `SurfaceControl` layer, shown on `ENTER`, hidden on exit), `DisplayHelper` (`DisplayManagerGlobal`/`DisplayInfo` logical size + rotation), `ServerMain`.
- Display size is re-read on every `ENTER`, so rotation between visits is handled.

---

## 4. Communication Protocol

Stream over the forwarded socket. Big-endian. Each packet is `type:u8` + payload (fixed size, except `CLIPBOARD`). Action codes everywhere: `0 = DOWN`, `1 = UP`.

| Type | Name | Direction | Payload |
| :--- | :--- | :--- | :--- |
| `0x01` | `HELLO` | Mac→Android | `version:u8` (=1), `token:32 ASCII bytes` |
| `0x02` | `HELLO_OK` | Android→Mac | `width:i32`, `height:i32`, `rotation:i32` |
| `0x04` | `ENTER` | Mac→Android | `edge:u8` (Android edge the pointer appears on: 0 left, 1 right, 2 top, 3 bottom), `along:f32` (0..1, vertical position for left/right, horizontal for top/bottom) |
| `0x05` | `EXIT` | Android→Mac | `along:f32` (0..1) |
| `0x06` | `LEAVE` | Mac→Android | none (Mac took control back, e.g. release chord) |
| `0x11` | `MOUSE_MOVE_REL` | Mac→Android | `dx:f32`, `dy:f32` (Android pixels) |
| `0x12` | `MOUSE_BUTTON` | Mac→Android | `button:u8` (Android `BUTTON_*` bit: 1 primary, 2 secondary, 4 tertiary), `action:u8` |
| `0x13` | `MOUSE_SCROLL` | Mac→Android | `h:f32`, `v:f32` (wheel lines; Android axis sign) |
| `0x20` | `KEY_EVENT` | Mac→Android | `keyCode:i32` (Android), `action:u8`, `metaState:i32` (Android) |
| `0x21` | `TEXT` | Mac→Android | `length:i32` (0..4096), `text:UTF-8 bytes` composed by a Mac input method; typed on the phone (ASCII as key events, anything else pasted through the clipboard with the previous text clip restored) |
| `0x30` | `CLIPBOARD` | both | `length:i32` (0..1 MiB), `text:UTF-8 bytes`. Mac→Android before `ENTER` (empty = share the clipboard this visit, nothing new to set); Android→Mac before `EXIT` or after `LEAVE`, only when the phone's clip differs from the one it had at `ENTER` |
| `0xFE` | `PING` | Mac→Android | none (every 2 s) |
| `0xFF` | `PONG` | Android→Mac | none |

Rules:
- The server accepts exactly one connection, requires `HELLO` first, and exits on a bad token, a bad version, an unknown packet type, 6 s without data, or EOF.
- The server ignores move/button/scroll/key packets while the pointer is not "entered".
- `EXIT` is only sent after the pointer has been at least 48 Android px away from the entry edge once ("armed"); the pointer starts exactly on that edge, so without this any jitter toward it hands control straight back.
- Clipboard sharing is opt-in per visit: the server reads or writes the phone's clipboard only after the Mac sent `CLIPBOARD` before `ENTER`. Text only; contents are never logged. The server reaches the clipboard as the shell user through the hidden `IClipboard` service (`ClipboardAccess`, arguments filled by type because the signature differs between Android versions).

---

## 5. Security Model

The server runs as shell UID with the power to inject arbitrary input, so access to its socket is access to the phone.

- **ADB transport boundary:** the DeskBridge server listens on an Android *abstract unix socket*, never its own TCP port. However, **Switch to Wi-Fi** runs `adb tcpip 5555`, exposing the phone's ADB daemon over the network. Legacy ADB TCP/IP does not encrypt the session's input or clipboard traffic; use a trusted network. Paired Android Wireless Debugging uses TLS, but pairing must be performed outside DeskBridge. See [AOSP's ADB Wi-Fi architecture](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/adb_wifi.md).
- **Unguessable endpoint:** the socket name is `deskbridge-<8 random hex>`, chosen per session by the Mac and passed as an argument.
- **Token:** a 32-hex-char random token (generated per session by the Mac, passed as an argument) must be the first thing sent (`HELLO`); compared in constant time. This also stops other local processes on the Mac that find the forwarded port.
- **Short life:** the server exits if nobody connects within 15 s and ends with the session.
- **Disconnect scope:** Disconnect Wi-Fi calls `adb disconnect <serial>`. It disconnects this Mac's transport; it does not disable the phone's network debugging listener. Turn off network debugging on the phone when finished.
- Process arguments are not visible to other Android apps (per-UID process isolation).

---

## 6. Requirements

- **macOS:** 14+ on Apple Silicon. Accessibility permission (Input Monitoring if prompted). Build with Xcode 16+/Swift 6 toolchain.
- **Android:** 13 (API 33) and newer is the supported range (verified on a Samsung running Android 13). Android 10 was also tried by hand and worked, older versions are not supported but may work. USB debugging enabled. Xiaomi/HyperOS and some other OEMs also need "USB debugging (Security settings)" for injection to work.
- **Dev tools:** JDK 17+ (`javac`, `jar`), Android SDK (`build-tools` for `d8`, any `platforms/android-*`), `adb`.

---

## 7. Known Risks & Non-Goals

**Risks (tracked by gates in the plan)**
1. ~~System pointer may not render for injected events~~ confirmed on Android 13: it does not. Mitigated by the server-drawn cursor (see §2). See the verified table below; OEMs other than Samsung are untested.
2. Hidden APIs (`InputManager.getInstance`, from Android 14 `InputManagerGlobal.getInstance`; `DisplayManagerGlobal`) can change per Android release; the spike script is the per-device regression check.
3. Latency: an earlier PING/PONG measurement over adb USB on a Galaxy Note10 Lite was p50 0.74 ms, p95 1.33 ms. The [2026-10-16 USB/Wi-Fi verification](WIRELESS_VERIFICATION.md) records the latest measurements; Wi-Fi exceeded the existing 25 ms transport p95 gate on that network. PING/PONG does not measure the Mac event tap, Android input injection, or display response; the end-to-end p95 < 10 ms target requires separate input/display measurement.
4. Hiding the cursor from a background (menu-bar) app is best effort.

**Verified on** (`scripts/device_matrix.sh` runs the emulator rows: pointer drawn, no "Untrusted touch" log, click opens the Phone app, injected Back leaves it)

| Android | Target | Result |
|---|---|---|
| 13 (API 33) | Samsung, real device | works (full MVP) |
| 10 (API 29) | real device, by hand | works |
| 14 (API 34) | emulator `google_apis` arm64 | works, needs `InputManagerGlobal` (`InputManager.getInstance()` throws NPE) |
| 15 (API 35) | emulator `google_apis` arm64 | works |
| 16 (API 36) | emulator `google_apis` arm64 | works |

Emulators have no OEM layer, so Samsung/Xiaomi behaviour on 14+ is still unverified on real hardware.

**Non-goals for MVP:** multiple simultaneous devices, rotation changes *during* a visit, display mirroring.
