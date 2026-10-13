# DeskBridge System Architecture

## 1. Overview & Vision

**DeskBridge** shares one Mac mouse and keyboard with a physical **Android** phone/tablet over a USB cable (similar to DeskDock, Synergy, or Logitech Flow).

When the Mac cursor pushes through the configured screen edge (left, right, top or bottom), control moves to the Android device. The cursor pushing back through the same edge returns control to the Mac. Keystrokes go to whichever device currently has control.

```
 +------------------------+                     +--------------------------+
 |      macOS (Host)      |                     |     Android (Target)     |
 |                        |                     |                          |
 |  CGEventTap thread     |                     |  deskbridge-server       |
 |        |               |                     |  (app_process, UID 2000) |
 |  DeviceSession         |   USB / adb         |        ^                 |
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
| **Keyboard** | Full Mac virtual keycode → Android keycode table; unmapped keys are dropped; Cmd/Ctrl → `META_CTRL` | Shortcuts like Cmd+C work. Text is not translated, so IME-composed text (Vietnamese Telex/VNI) is **out of MVP**. |
| **Right click** | Mac sends `KEYCODE_BACK` by default (toggle: real secondary button) | scrcpy does the same; the Android framework does not turn an injected secondary click into Back. |
| **Transport** | `adb forward tcp:0 localabstract:<random>` + per-session random token | adb allocates a free local port (multi-device safe). Abstract socket, not a TCP port on the phone, so nothing is exposed to the Wi-Fi network. See §5. |
| **Mac concurrency** | Tap callback on a dedicated thread; all session state on one serial `DispatchQueue`; only the "remote?" flag is shared (unfair lock) | Keeps the tap callback fast (macOS disables slow taps). |

---

## 3. Subsystem Breakdown

### 3.1 macOS (`mac/`, SwiftPM)
- **`DeskBridgeCore` (library):** protocol codec, `ADBBridge`/`ServerLauncher`, `Connection`, `MoveCoalescer`, `KeyMapper`, `EdgeDetector`, `InputCapturer`, `DeviceSession`, `Settings`. Unit-testable without UI.
- **`DeskBridge` (executable):** SwiftUI `MenuBarExtra` + `AppModel` (device discovery loop, permission check).
- **Event tap:** `CGEvent.tapCreate` at `.cghidEventTap`, active filter. Captures mouse move/drag (all buttons), buttons, scroll, key down/up. In local mode events pass through; in remote mode they are swallowed. Re-enables itself on `tapDisabledByTimeout`.
- **Edges:** computed per display (`EdgeDetector`): an edge counts only where no other display sits right behind it. Top and bottom only count on the **main display**, so a tall or rotated secondary display never blocks the way. Left and right use every exposed edge. Control returns to the display it left from.
- **Remote mode:** park the frozen cursor, cover that display with a near-invisible `CursorShield` window (so this app owns the cursor image) and hide it; read `mouseEventDeltaX/Y`. The warp's own synthetic move is ignored for 150 ms.
- **Fail-safes:** release chord **⌃⌥⌘⎋**; control returns to the Mac automatically on disconnect, server exit, or 6 s without a packet.
- **Device lifecycle:** poll `adb devices` while no session is active; push jar, `forward`, spawn server, connect with retry until the server listens (≤ 8 s).
- **Packaging:** `scripts/package_app.sh` builds `DeskBridge.app` (window + menu bar item, jar in Resources, codesigned) because Accessibility/Input Monitoring permissions attach to a signed bundle.

### 3.2 Android server (`server/`, plain Java, no Gradle)
- Built with `javac --release 11` against the SDK `android.jar`, then `d8 --min-api 26`, zipped as `deskbridge-server.jar`.
- Entry: `app_process / com.deskbridge.server.ServerMain <socketName> <token>`.
- Pure-Java, unit-tested logic: `ProtocolDecoder`, `PointerState` (position, clamping, edge exit).
- Android-bound: `InputInjector`, `CursorOverlay` (arrow drawn into a `SurfaceControl` layer, shown on `ENTER`, hidden on exit), `DisplayHelper` (`DisplayManagerGlobal`/`DisplayInfo` logical size + rotation), `ServerMain`.
- Display size is re-read on every `ENTER`, so rotation between visits is handled.

---

## 4. Communication Protocol

Stream over the forwarded socket. Big-endian. Each packet is `type:u8` + fixed payload. Action codes everywhere: `0 = DOWN`, `1 = UP`.

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
| `0xFE` | `PING` | Mac→Android | none (every 2 s) |
| `0xFF` | `PONG` | Android→Mac | none |

Rules:
- The server accepts exactly one connection, requires `HELLO` first, and exits on a bad token, a bad version, an unknown packet type, 6 s without data, or EOF.
- The server ignores move/button/scroll/key packets while the pointer is not "entered".
- `CLIPBOARD_SYNC` is not part of the MVP.

---

## 5. Security Model

The server runs as shell UID with the power to inject arbitrary input, so access to its socket is access to the phone.

- **No network exposure:** the server listens on an Android *abstract unix socket*, never a TCP port. Nothing is reachable from Wi-Fi.
- **Unguessable endpoint:** the socket name is `deskbridge-<8 random hex>`, chosen per session by the Mac and passed as an argument.
- **Token:** a 32-hex-char random token (generated per session by the Mac, passed as an argument) must be the first thing sent (`HELLO`); compared in constant time. This also stops other local processes on the Mac that find the forwarded port.
- **Short life:** the server exits if nobody connects within 15 s and ends with the session.
- Process arguments are not visible to other Android apps (per-UID process isolation).

---

## 6. Requirements

- **macOS:** 14+ on Apple Silicon. Accessibility permission (Input Monitoring if prompted). Build with Xcode 16+/Swift 6 toolchain.
- **Android:** 8.0 (API 26) and up, including Android 16 (API 36). USB debugging enabled. Xiaomi/HyperOS and some other OEMs also need "USB debugging (Security settings)" for injection to work.
- **Dev tools:** JDK 17+ (`javac`, `jar`), Android SDK (`build-tools` for `d8`, any `platforms/android-*`), `adb`.

---

## 7. Known Risks & Non-Goals

**Risks (tracked by gates in the plan)**
1. ~~System pointer may not render for injected events~~ confirmed on Android 13: it does not. Mitigated by the server-drawn cursor (see §2). Untested on other Android versions/OEMs.
2. Hidden APIs (`InputManager.getInstance`, `DisplayManagerGlobal`) can change per Android release; the spike script is the per-device regression check.
3. Latency: measured PING/PONG round trip over adb USB on a Galaxy Note10 Lite: p50 0.74 ms, p95 1.33 ms (one way about 0.4 ms). End-to-end adds Mac event tap + Android injection; target p95 < 10 ms, re-measure with `pingRoundTripLatency` and a video capture.
4. Hiding the cursor from a background (menu-bar) app is best effort.

**Non-goals for MVP:** clipboard sync, Vietnamese/IME text input, multiple simultaneous devices, wireless ADB, rotation changes *during* a visit, display mirroring.
