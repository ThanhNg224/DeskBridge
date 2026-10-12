# DeskBridge System Architecture

## 1. Overview & Vision

**DeskBridge** is a modern, high-performance mouse and keyboard sharing utility connecting **macOS (Apple Silicon)** and **Android** as independent physical displays (similar to DeskDock, Synergy, or Logitech Flow).

When the mouse cursor reaches the edge of the macOS screen, it seamlessly transitions onto the physical Android screen. Keystrokes are directed to whichever device currently holds cursor focus.

```
 +------------------------+                  +------------------------+
 |     macOS (Host)       |                  |    Android (Target)    |
 |  Apple Silicon Native  |                  |   Physical Hardware    |
 |                        |                  |                        |
 |  +------------------+  |                  |  +------------------+  |
 |  |  Swift Controller|  |                  |  | deskbridge-server|  |
 |  |   (CGEventTap)   |  |                  |  |   (app_process)  |  |
 |  +--------+---------+  |                  |  +--------^---------+  |
 |           |            |                  |           |            |
 |  +--------v---------+  |                  |  +--------+---------+  |
 |  |  TCP Client (Mac)|  |  USB ADB Tunnel  |  | TCP Server (DEX) |  |
 |  |  127.0.0.1:28282 +--+==================+->:28282 (Loopback)  |  |
 |  +------------------+  | adb forward tcp  |  +--------+---------+  |
 +------------------------+                  |           |            |
                                             |  +--------v---------+  |
                                             |  |   InputManager   |  |
                                             |  |  (Native Pointer)|  |
                                             |  +------------------+  |
                                             +------------------------+
```

---

## 2. Core Decisions & Trade-Offs (Accepted)

| Component | Selected Strategy | Rationale & Trade-offs |
| :--- | :--- | :--- |
| **Android Server Model** | **Standalone JAR via `app_process` (UID 2000)** | **Zero-install on Android**. Pushed to `/data/local/tmp/`. Possesses `INJECT_EVENTS` system permission out of the box. Immune to Android OS background battery optimization / Doze mode. Trade-off: Requires USB debugging enabled. |
| **Input Injection** | **Native `InputManager.injectInputEvent` via Reflection** | Android renders its **genuine hardware mouse pointer** at full display refresh rate (90Hz/120Hz). Zero jitter, native hover, native scrolling, native drag-and-drop. Trade-off: Uses hidden Android APIs. |
| **Keyboard Forwarding** | **Raw Keycode + Modifier Remap (`Cmd` -> `Ctrl`)** | Immediate latency-free key repeats and shortcut execution. Automatic remapping translates `Cmd+C` on Mac to `Ctrl+C` on Android. Trade-off: Vietnamese text input uses Android's active physical keyboard IME engine. |
| **Right-Click Action** | **`BACK` button by default** (with toggle for Context Menu) | 95% of smartphone mouse workflows require quick Back navigation rather than desktop-style context menus. |
| **Transport Layer** | **Local TCP over ADB Port Forward (`adb forward`)** | Sub-millisecond latency (< 1ms), 100% immune to Wi-Fi jitter or packet drops, charges device concurrently. |

---

## 3. Subsystem Breakdown

### 3.1 macOS Controller (`deskbridge-mac`)
- **Technology:** Swift 6, SwiftUI (Settings/Menu Bar), AppKit, CoreGraphics.
- **Event Tap:** `CGEventTapCreate` at `kCGHIDEventTap` level capturing:
  - Mouse Moved, Mouse Down/Up (Left, Right, Other), Scroll Wheel.
  - Key Down, Key Up, Flags Changed (Shift, Control, Option, Command).
- **Edge Transition Logic:**
  - Configurable edge boundary (Right, Left, Top, Bottom).
  - Transition trigger: Cursor reaches edge coordinate with outward delta.
  - Cursor Locking: Mac cursor locked at the edge (or invisible cursor positioned) while control is ceded to Android.
  - Release trigger: Virtual cursor hits Android opposite edge returning to Mac.
- **ADB Automation:**
  - Monitors `adb devices -l` for device connection events.
  - Runs `adb forward tcp:28282 tcp:28282`.
  - Pushes `deskbridge-server.jar` to `/data/local/tmp/`.
  - Spawns server via `adb shell app_process ...`.

### 3.2 Android Server Daemon (`deskbridge-server`)
- **Technology:** Java/Kotlin compiled to Android DEX/JAR (Android SDK 26+).
- **Process Entry:** Standard `public static void main(String[] args)` executed via `app_process /system/bin com.deskbridge.server.ServerMain`.
- **Hidden API Bridge:**
  - Accesses `android.hardware.input.IInputManager` / `InputManager.getInstance()` via Java Reflection.
  - Constructs `MotionEvent` with `InputDevice.SOURCE_MOUSE` and `MotionEvent.TOOL_TYPE_MOUSE`.
  - Constructs `KeyEvent` with `InputDevice.SOURCE_KEYBOARD`.
- **Display Resolution & Coordinate Scaling:**
  - Query device display metrics (`DisplayManager` / `SurfaceControl.getDynamicDisplayInfo` or `IWindowManager`).
  - Converts normalized coordinates `(normX: 0.0 .. 1.0, normY: 0.0 .. 1.0)` or relative deltas `(dx, dy)` into physical display pixels adjusted for screen orientation (0, 90, 180, 270 degrees).

---

## 4. Communication Protocol (Binary Packet Specification)

Communication runs over a stream TCP socket. Every packet starts with a 1-byte `PacketType` followed by a fixed-length payload.

### Packet Types:
- `0x01` - `HANDSHAKE_INIT` (Mac -> Android): Client protocol version, configuration.
- `0x02` - `HANDSHAKE_RESP` (Android -> Mac): Display width, display height, orientation, density.
- `0x10` - `MOUSE_MOVE_ABS` (Mac -> Android): Absolute target coordinates `[x: Float32, y: Float32]`.
- `0x11` - `MOUSE_MOVE_REL` (Mac -> Android): Relative movement delta `[dx: Float32, dy: Float32]`.
- `0x12` - `MOUSE_BUTTON` (Mac -> Android): Button ID `[button: UInt8, action: UInt8]` (action: 0=UP, 1=DOWN).
- `0x13` - `MOUSE_SCROLL` (Mac -> Android): Scroll deltas `[hScroll: Float32, vScroll: Float32]`.
- `0x20` - `KEY_EVENT` (Mac -> Android): Keycode `[keyCode: Int32, action: UInt8, metaState: Int32]`.
- `0x30` - `CLIPBOARD_SYNC` (Bidirectional): Length prefix + UTF-8 payload.
- `0xFE` - `PING` / `0xFF` - `PONG`: Heartbeat.

---

## 5. Security & System Requirements
- **macOS:** macOS 13+ (Ventura, Sonoma, Sequoia) on Apple Silicon (M1/M2/M3/M4). Accessibility permission enabled in System Settings.
- **Android:** Android 8.0 (API 26) through Android 15/16. Developer Options + USB Debugging enabled.
- **Development Tools:** Xcode 16+, Swift 6, JDK 17+, Android SDK Platform Tools (ADB).
