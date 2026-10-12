# DeskBridge Implementation Plan

> Steps use checkbox (`- [ ]`) syntax. Tasks are ordered by dependency. **Status:** all tasks implemented; Task 2 gate result is recorded below. The code in `server/` and `mac/` is the source of truth; code blocks here are the original design and may lag it.

**Goal:** A low-latency DeskDock alternative for macOS (Apple Silicon) and Android that shares the Mac mouse and keyboard across the screen edge over a USB/ADB tunnel, with no APK installed on the phone.

**Architecture:** A Swift menu-bar app captures input with `CGEventTap`, runs a Mac⇄Android control state machine, and streams a small binary protocol to a plain-Java server started on the phone with `app_process` (shell UID). The server owns the Android pointer position and injects events through `InputManager`. See [ARCHITECTURE.md](ARCHITECTURE.md).

**Tech stack:** Swift 6 / SwiftUI / Network.framework / Swift Testing (macOS 14+); plain Java 11 bytecode + `d8` (Android API 26+); shell scripts (no Gradle); ADB.

---

## Global Constraints

- **No APK on Android.** Server = DEX jar via `app_process`, shell UID.
- **No network exposure.** Server listens on an abstract unix socket with a random name and requires a random token (see ARCHITECTURE §5). Never bind a TCP port on the phone.
- **Protocol is the contract.** `ProtocolDecoder.java` and `Packets.swift` must match ARCHITECTURE §4 byte for byte. Action codes: `0 = DOWN`, `1 = UP`.
- **Fail fast, no silent fallbacks.** Reflection or injection failure ends the session with a message; the Mac surfaces it.
- **Mac fail-safes are mandatory:** release chord ⌃⌥⌘⎋, auto-release on disconnect / server exit / 6 s silence.
- **Dependencies:** none beyond JDK, Android SDK build-tools, adb, Xcode toolchain.

---

## Directory Structure

```
DeskBridge/
├── .gitignore
├── README.md
├── docs/{ARCHITECTURE.md, IMPLEMENTATION_PLAN.md}
├── scripts/
│   ├── build_server.sh        # javac + d8 -> server/build/deskbridge-server.jar
│   ├── test_server.sh         # pure-Java unit tests
│   ├── run_on_device.sh       # push jar + run any main class on the device
│   ├── run_server_dev.sh      # run ServerMain with fresh name/token + adb forward
│   └── package_app.sh         # build DeskBridge.app (bundle + codesign)
├── server/src/
│   ├── main/java/com/deskbridge/server/
│   │   ├── ServerMain.java
│   │   ├── InputInjector.java
│   │   ├── DisplayHelper.java
│   │   ├── PointerState.java
│   │   ├── PointerSpike.java          # diagnostic / gate tool
│   │   └── protocol/{PacketType.java, ProtocolDecoder.java}
│   └── test/java/com/deskbridge/server/Tests.java
└── mac/
    ├── Package.swift
    ├── Sources/DeskBridgeCore/
    │   ├── Protocol/Packets.swift
    │   ├── Network/{ADBBridge.swift, ServerLauncher.swift, Connection.swift}
    │   ├── Core/{MoveCoalescer, KeyMapper, EdgeDetector, InputCapturer, DeviceSession}.swift
    │   └── Config/{Settings.swift, ServerJar.swift}
    ├── Sources/DeskBridge/{DeskBridgeApp.swift, AppModel.swift, MenuBarView.swift}
    └── Tests/DeskBridgeCoreTests/
```

---

## Tasks

### Task 1: Server build scripts, protocol decoder, pointer logic (pure Java, tested)

**Files:**
- Create: `scripts/build_server.sh`, `scripts/test_server.sh`
- Create: `server/src/main/java/com/deskbridge/server/protocol/PacketType.java`
- Create: `server/src/main/java/com/deskbridge/server/protocol/ProtocolDecoder.java`
- Create: `server/src/main/java/com/deskbridge/server/PointerState.java`
- Create: `server/src/test/java/com/deskbridge/server/Tests.java`

**Interfaces:**
- Produces: `server/build/deskbridge-server.jar` (zip containing `classes.dex`); `ProtocolDecoder.Listener` callbacks; `PointerState` (position, clamping, edge exit).

- [ ] **Step 1: Create `server/src/main/java/com/deskbridge/server/protocol/PacketType.java`**

```java
package com.deskbridge.server.protocol;

public final class PacketType {
    private PacketType() {}

    public static final int VERSION = 1;
    public static final int TOKEN_LENGTH = 32;

    public static final byte HELLO          = 0x01;
    public static final byte HELLO_OK       = 0x02;
    public static final byte ENTER          = 0x04;
    public static final byte EXIT           = 0x05;
    public static final byte LEAVE          = 0x06;
    public static final byte MOUSE_MOVE_REL = 0x11;
    public static final byte MOUSE_BUTTON   = 0x12;
    public static final byte MOUSE_SCROLL   = 0x13;
    public static final byte KEY_EVENT      = 0x20;
    public static final byte PING           = (byte) 0xFE;
    public static final byte PONG           = (byte) 0xFF;
}
```

- [ ] **Step 2: Create `server/src/main/java/com/deskbridge/server/PointerState.java`**

```java
package com.deskbridge.server;

/** Android-side pointer position for one "visit". Pure logic, no Android dependencies. */
public final class PointerState {
    public static final int EDGE_LEFT = 0;
    public static final int EDGE_RIGHT = 1;

    private int width;
    private int height;
    private int entryEdge;
    private boolean entered;
    private float x;
    private float y;

    /** `along` (0..1) is the position along the entry edge. */
    public void enter(int width, int height, int edge, float along) {
        this.width = width;
        this.height = height;
        this.entryEdge = edge;
        this.entered = true;
        this.x = edge == EDGE_LEFT ? 0 : width - 1;
        this.y = clamp(along * (height - 1), 0, height - 1);
    }

    public void leave() {
        entered = false;
    }

    public boolean isEntered() { return entered; }
    public float x() { return x; }
    public float y() { return y; }

    /** Normalized position along the vertical axis, for EXIT. */
    public float along() {
        return height > 1 ? y / (height - 1) : 0f;
    }

    /**
     * Applies a relative move. Returns true when the pointer pushed back through the entry edge;
     * the visit is then over (isEntered() == false) and the position stays on that edge.
     */
    public boolean moveBy(float dx, float dy) {
        float nx = x + dx;
        boolean exit = (entryEdge == EDGE_LEFT && nx < 0) || (entryEdge == EDGE_RIGHT && nx > width - 1);
        y = clamp(y + dy, 0, height - 1);
        if (exit) {
            entered = false;
            return true;
        }
        x = clamp(nx, 0, width - 1);
        return false;
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
```

- [ ] **Step 3: Create failing tests `server/src/test/java/com/deskbridge/server/Tests.java`**

Plain-Java runner (no JUnit, no Gradle): prints one line per case and exits non-zero on failure.

```java
package com.deskbridge.server;

import com.deskbridge.server.protocol.PacketType;
import com.deskbridge.server.protocol.ProtocolDecoder;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class Tests {
    private interface Case { void run() throws Exception; }

    public static void main(String[] args) {
        int failed = 0;
        String[] names = {
            "decodeEnterAndLeave", "decodeMoveButtonScrollKey", "decodePing", "unknownPacketThrows",
            "eofReturnsFalse", "helloAccepted", "helloRejectsBadVersion", "helloRejectsWrongType",
            "pointerEnterLeftPlacesAtEdge", "pointerClamps", "pointerExitsThroughEntryEdge", "pointerAlong"
        };
        Case[] cases = {
            Tests::decodeEnterAndLeave, Tests::decodeMoveButtonScrollKey, Tests::decodePing, Tests::unknownPacketThrows,
            Tests::eofReturnsFalse, Tests::helloAccepted, Tests::helloRejectsBadVersion, Tests::helloRejectsWrongType,
            Tests::pointerEnterLeftPlacesAtEdge, Tests::pointerClamps, Tests::pointerExitsThroughEntryEdge, Tests::pointerAlong
        };
        for (int i = 0; i < cases.length; i++) {
            try {
                cases[i].run();
                System.out.println("PASS " + names[i]);
            } catch (Throwable t) {
                failed++;
                System.out.println("FAIL " + names[i] + ": " + t);
            }
        }
        System.out.println(failed == 0 ? "OK " + cases.length + " tests" : failed + " FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }

    // ---- helpers ----

    private static final class Recorder implements ProtocolDecoder.Listener {
        final List<String> events = new ArrayList<>();
        @Override public void onEnter(int edge, float along) { events.add("enter " + edge + " " + along); }
        @Override public void onLeave() { events.add("leave"); }
        @Override public void onMouseMoveRel(float dx, float dy) { events.add("move " + dx + " " + dy); }
        @Override public void onMouseButton(int button, int action) { events.add("button " + button + " " + action); }
        @Override public void onMouseScroll(float h, float v) { events.add("scroll " + h + " " + v); }
        @Override public void onKeyEvent(int keyCode, int action, int metaState) { events.add("key " + keyCode + " " + action + " " + metaState); }
        @Override public void onPing() { events.add("ping"); }
    }

    private static DataInputStream stream(byte[] bytes) {
        return new DataInputStream(new ByteArrayInputStream(bytes));
    }

    private static byte[] build(Writer w) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        w.write(new DataOutputStream(bos));
        return bos.toByteArray();
    }

    private interface Writer { void write(DataOutputStream out) throws IOException; }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void eq(Object expected, Object actual) {
        if (!expected.equals(actual)) throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
    }

    private static void near(float expected, float actual) {
        if (Math.abs(expected - actual) > 0.001f) throw new AssertionError("expected " + expected + " but was " + actual);
    }

    private static final String TOKEN = "0123456789abcdef0123456789abcdef";

    // ---- decoder ----

    static void decodeEnterAndLeave() throws Exception {
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.ENTER); o.writeByte(1); o.writeFloat(0.25f);
            o.writeByte(PacketType.LEAVE);
        });
        Recorder r = new Recorder();
        ProtocolDecoder d = new ProtocolDecoder(r);
        DataInputStream in = stream(bytes);
        check(d.processNext(in), "enter");
        check(d.processNext(in), "leave");
        eq("enter 1 0.25", r.events.get(0));
        eq("leave", r.events.get(1));
    }

    static void decodeMoveButtonScrollKey() throws Exception {
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.MOUSE_MOVE_REL); o.writeFloat(-3.5f); o.writeFloat(7.25f);
            o.writeByte(PacketType.MOUSE_BUTTON); o.writeByte(2); o.writeByte(0);
            o.writeByte(PacketType.MOUSE_SCROLL); o.writeFloat(0f); o.writeFloat(-1.5f);
            o.writeByte(PacketType.KEY_EVENT); o.writeInt(29); o.writeByte(1); o.writeInt(0x1000);
        });
        Recorder r = new Recorder();
        ProtocolDecoder d = new ProtocolDecoder(r);
        DataInputStream in = stream(bytes);
        while (d.processNext(in)) { /* drain */ }
        eq(4, r.events.size());
        eq("move -3.5 7.25", r.events.get(0));
        eq("button 2 0", r.events.get(1));
        eq("scroll 0.0 -1.5", r.events.get(2));
        eq("key 29 1 4096", r.events.get(3));
    }

    static void decodePing() throws Exception {
        Recorder r = new Recorder();
        new ProtocolDecoder(r).processNext(stream(new byte[]{PacketType.PING}));
        eq("ping", r.events.get(0));
    }

    static void unknownPacketThrows() throws Exception {
        try {
            new ProtocolDecoder(new Recorder()).processNext(stream(new byte[]{0x7E}));
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("expected IOException");
    }

    static void eofReturnsFalse() throws Exception {
        check(!new ProtocolDecoder(new Recorder()).processNext(stream(new byte[0])), "EOF must return false");
    }

    static void helloAccepted() throws Exception {
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.HELLO); o.writeByte(PacketType.VERSION);
            o.write(TOKEN.getBytes(StandardCharsets.US_ASCII));
        });
        eq(TOKEN, ProtocolDecoder.readHello(stream(bytes)));
    }

    static void helloRejectsBadVersion() throws Exception {
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.HELLO); o.writeByte(99);
            o.write(TOKEN.getBytes(StandardCharsets.US_ASCII));
        });
        try {
            ProtocolDecoder.readHello(stream(bytes));
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("expected IOException");
    }

    static void helloRejectsWrongType() throws Exception {
        try {
            ProtocolDecoder.readHello(stream(new byte[]{PacketType.PING}));
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("expected IOException");
    }

    // ---- pointer ----

    static void pointerEnterLeftPlacesAtEdge() {
        PointerState p = new PointerState();
        p.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(p.isEntered(), "entered");
        near(0f, p.x());
        near(1199.5f, p.y());
        p.enter(1080, 2400, PointerState.EDGE_RIGHT, 0f);
        near(1079f, p.x());
        near(0f, p.y());
    }

    static void pointerClamps() {
        PointerState p = new PointerState();
        p.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(!p.moveBy(5000f, 99999f), "no exit moving inward");
        near(1079f, p.x());
        near(2399f, p.y());
        check(!p.moveBy(-10f, -99999f), "no exit while inside");
        near(1069f, p.x());
        near(0f, p.y());
    }

    static void pointerExitsThroughEntryEdge() {
        PointerState left = new PointerState();
        left.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(left.moveBy(-1f, 0f), "left entry exits on negative x");
        check(!left.isEntered(), "visit over");

        PointerState right = new PointerState();
        right.enter(1080, 2400, PointerState.EDGE_RIGHT, 0.5f);
        check(!right.moveBy(-100f, 0f), "moving inward does not exit");
        check(right.moveBy(5000f, 0f), "right entry exits past width");
    }

    static void pointerAlong() {
        PointerState p = new PointerState();
        p.enter(1080, 2401, PointerState.EDGE_LEFT, 0.25f);
        near(0.25f, p.along());
    }
}
```

- [ ] **Step 4: Create `scripts/test_server.sh`**

```bash
#!/usr/bin/env bash
# Compiles and runs the pure-Java unit tests (no Android SDK needed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/server/build/test-classes"
rm -rf "$OUT" && mkdir -p "$OUT"

javac --release 11 -d "$OUT" \
  "$ROOT"/server/src/main/java/com/deskbridge/server/protocol/*.java \
  "$ROOT"/server/src/main/java/com/deskbridge/server/PointerState.java \
  "$ROOT"/server/src/test/java/com/deskbridge/server/Tests.java

java -ea -cp "$OUT" com.deskbridge.server.Tests
```

- [ ] **Step 5: Run test to verify it fails**

Run: `chmod +x scripts/*.sh && scripts/test_server.sh`
Expected: compile error (`ProtocolDecoder` missing).

- [ ] **Step 6: Create `server/src/main/java/com/deskbridge/server/protocol/ProtocolDecoder.java`**

```java
package com.deskbridge.server.protocol;

import java.io.DataInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public final class ProtocolDecoder {

    /** Callbacks may throw IOException (they write replies) or unchecked exceptions (injection failures). */
    public interface Listener {
        void onEnter(int edge, float along) throws IOException;
        void onLeave() throws IOException;
        void onMouseMoveRel(float dx, float dy) throws IOException;
        void onMouseButton(int button, int action) throws IOException;
        void onMouseScroll(float hScroll, float vScroll) throws IOException;
        void onKeyEvent(int keyCode, int action, int metaState) throws IOException;
        void onPing() throws IOException;
    }

    private final Listener listener;

    public ProtocolDecoder(Listener listener) {
        this.listener = listener;
    }

    /** Reads the mandatory first packet and returns its token. Rejects anything else. */
    public static String readHello(DataInputStream in) throws IOException {
        int type = in.readUnsignedByte();
        if (type != (PacketType.HELLO & 0xFF)) {
            throw new IOException("Expected HELLO, got type " + type);
        }
        int version = in.readUnsignedByte();
        if (version != PacketType.VERSION) {
            throw new IOException("Unsupported protocol version " + version);
        }
        byte[] token = new byte[PacketType.TOKEN_LENGTH];
        in.readFully(token);
        return new String(token, StandardCharsets.US_ASCII);
    }

    /** Reads one packet. Returns false on clean EOF. */
    public boolean processNext(DataInputStream in) throws IOException {
        int typeByte = in.read();
        if (typeByte == -1) {
            return false;
        }
        switch ((byte) typeByte) {
            case PacketType.ENTER: {
                int edge = in.readUnsignedByte();
                float along = in.readFloat();
                listener.onEnter(edge, along);
                return true;
            }
            case PacketType.LEAVE:
                listener.onLeave();
                return true;
            case PacketType.MOUSE_MOVE_REL: {
                float dx = in.readFloat();
                float dy = in.readFloat();
                listener.onMouseMoveRel(dx, dy);
                return true;
            }
            case PacketType.MOUSE_BUTTON: {
                int button = in.readUnsignedByte();
                int action = in.readUnsignedByte();
                listener.onMouseButton(button, action);
                return true;
            }
            case PacketType.MOUSE_SCROLL: {
                float h = in.readFloat();
                float v = in.readFloat();
                listener.onMouseScroll(h, v);
                return true;
            }
            case PacketType.KEY_EVENT: {
                int keyCode = in.readInt();
                int action = in.readUnsignedByte();
                int metaState = in.readInt();
                listener.onKeyEvent(keyCode, action, metaState);
                return true;
            }
            case PacketType.PING:
                listener.onPing();
                return true;
            default:
                throw new IOException("Unknown packet type: " + typeByte);
        }
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `scripts/test_server.sh`
Expected: `OK 12 tests`.

- [ ] **Step 8: Create `scripts/build_server.sh`**

```bash
#!/usr/bin/env bash
# javac (against the SDK android.jar) -> d8 -> deskbridge-server.jar (zip with classes.dex).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"

ANDROID_JAR="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1 || true)"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
[ -f "$ANDROID_JAR" ] || { echo "No platforms/android-*/android.jar under $SDK (set ANDROID_HOME)" >&2; exit 1; }
[ -x "$BUILD_TOOLS/d8" ] || { echo "No build-tools/*/d8 under $SDK (set ANDROID_HOME)" >&2; exit 1; }

OUT="$ROOT/server/build"
rm -rf "$OUT/classes" "$OUT/dex" "$OUT/classes.jar" "$OUT/deskbridge-server.jar"
mkdir -p "$OUT/classes" "$OUT/dex"

find "$ROOT/server/src/main" -name '*.java' > "$OUT/sources.txt"
javac --release 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$OUT/classes" @"$OUT/sources.txt"
jar cf "$OUT/classes.jar" -C "$OUT/classes" .

"$BUILD_TOOLS/d8" --release --min-api 26 --lib "$ANDROID_JAR" --output "$OUT/dex" "$OUT/classes.jar"
(cd "$OUT/dex" && zip -q "$OUT/deskbridge-server.jar" classes.dex)

echo "Built $OUT/deskbridge-server.jar"
```

- [ ] **Step 9: Build and commit**

Run: `scripts/build_server.sh && unzip -l server/build/deskbridge-server.jar`
Expected: `Built .../deskbridge-server.jar`; listing shows `classes.dex`.

```bash
git add scripts/ server/
git commit -m "feat(server): add javac+d8 build, protocol decoder and pointer state with tests"
```

---

### Task 2: Android `InputInjector` + `PointerSpike` — **DECISION GATE**

**Files:**
- Create: `server/src/main/java/com/deskbridge/server/DisplayHelper.java`
- Create: `server/src/main/java/com/deskbridge/server/InputInjector.java`
- Create: `server/src/main/java/com/deskbridge/server/PointerSpike.java`
- Create: `scripts/run_on_device.sh`

**Interfaces:**
- Produces: `InputInjector` (`hover`, `hoverExit`, `button`, `scroll`, `key`, `releaseAll`), `DisplayHelper.query()`, a diagnostic that exercises them on a real device.

- [ ] **Step 1: Create `server/src/main/java/com/deskbridge/server/DisplayHelper.java`**

```java
package com.deskbridge.server;

/** Logical display size/rotation (what injected coordinates are relative to), via hidden APIs. */
final class DisplayHelper {
    static final class Size {
        final int width;
        final int height;
        final int rotation;

        Size(int width, int height, int rotation) {
            this.width = width;
            this.height = height;
            this.rotation = rotation;
        }
    }

    private DisplayHelper() {}

    static Size query() throws ReflectiveOperationException {
        Class<?> manager = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object instance = manager.getMethod("getInstance").invoke(null);
        Object info = manager.getMethod("getDisplayInfo", int.class).invoke(instance, 0);
        Class<?> infoClass = info.getClass();
        return new Size(
                infoClass.getField("logicalWidth").getInt(info),
                infoClass.getField("logicalHeight").getInt(info),
                infoClass.getField("rotation").getInt(info));
    }
}
```

- [ ] **Step 2: Create `server/src/main/java/com/deskbridge/server/InputInjector.java`**

```java
package com.deskbridge.server;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Injects mouse and keyboard events through the hidden InputManager. Failures are unchecked (fail fast). */
public final class InputInjector {
    private static final int MOUSE_DEVICE_ID = 0;
    private static final int KEYBOARD_DEVICE_ID = -1; // KeyCharacterMap.VIRTUAL_KEYBOARD
    private static final int INJECT_MODE_ASYNC = 0;

    private final Object inputManager;
    private final Method injectMethod;
    private final Method setActionButtonMethod; // @hide in the SDK stubs, so reflected like the rest
    private int buttonState;
    private long downTime;
    private long keyDownTime;

    public InputInjector() throws ReflectiveOperationException {
        Class<?> managerClass = Class.forName("android.hardware.input.InputManager");
        Method getInstance = managerClass.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        inputManager = getInstance.invoke(null);
        injectMethod = managerClass.getMethod("injectInputEvent", InputEvent.class, int.class);
        setActionButtonMethod = MotionEvent.class.getMethod("setActionButton", int.class);
    }

    /** Moves the pointer; a drag if a button is held, a hover otherwise. */
    public void hover(float x, float y) {
        motion(buttonState == 0 ? MotionEvent.ACTION_HOVER_MOVE : MotionEvent.ACTION_MOVE, x, y, 0, 0f, 0f);
    }

    public void hoverExit(float x, float y) {
        motion(MotionEvent.ACTION_HOVER_EXIT, x, y, 0, 0f, 0f);
    }

    /** button is an Android MotionEvent.BUTTON_* bit. */
    public void button(int button, boolean down, float x, float y) {
        if (down) {
            boolean first = buttonState == 0;
            buttonState |= button;
            if (first) {
                downTime = SystemClock.uptimeMillis();
                motion(MotionEvent.ACTION_DOWN, x, y, 0, 0f, 0f);
            }
            motion(MotionEvent.ACTION_BUTTON_PRESS, x, y, button, 0f, 0f);
        } else {
            buttonState &= ~button;
            motion(MotionEvent.ACTION_BUTTON_RELEASE, x, y, button, 0f, 0f);
            if (buttonState == 0) {
                motion(MotionEvent.ACTION_UP, x, y, 0, 0f, 0f);
            }
        }
    }

    /** Wheel lines, Android axis sign (positive vertical = up). */
    public void scroll(float x, float y, float h, float v) {
        motion(MotionEvent.ACTION_SCROLL, x, y, 0, h, v);
    }

    /** action: KeyEvent.ACTION_DOWN (0) / ACTION_UP (1). */
    public void key(int keyCode, int action, int metaState) {
        long now = SystemClock.uptimeMillis();
        if (action == KeyEvent.ACTION_DOWN) {
            keyDownTime = now;
        }
        inject(new KeyEvent(keyDownTime, now, action, keyCode, 0, metaState,
                KEYBOARD_DEVICE_ID, 0, 0, InputDevice.SOURCE_KEYBOARD));
    }

    /** Releases any held mouse buttons so nothing stays pressed after a session ends. */
    public void releaseAll(float x, float y) {
        for (int bit = 1; bit <= 0x10 && buttonState != 0; bit <<= 1) {
            if ((buttonState & bit) != 0) {
                button(bit, false, x, y);
            }
        }
    }

    private void motion(int action, float x, float y, int actionButton, float hScroll, float vScroll) {
        long now = SystemClock.uptimeMillis();

        MotionEvent.PointerProperties[] props = {new MotionEvent.PointerProperties()};
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;

        MotionEvent.PointerCoords[] coords = {new MotionEvent.PointerCoords()};
        coords[0].x = x;
        coords[0].y = y;
        coords[0].pressure = buttonState != 0 ? 1f : 0f;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll);

        MotionEvent event = MotionEvent.obtain(downTime, now, action, 1, props, coords,
                0, buttonState, 1f, 1f, MOUSE_DEVICE_ID, 0, InputDevice.SOURCE_MOUSE, 0);
        try {
            if (actionButton != 0) {
                setActionButtonMethod.invoke(event, actionButton);
            }
            inject(event);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("setActionButton failed: " + e, e);
        } finally {
            event.recycle();
        }
    }

    private void inject(InputEvent event) {
        try {
            injectMethod.invoke(inputManager, event, INJECT_MODE_ASYNC);
        } catch (InvocationTargetException e) {
            throw new IllegalStateException("Input injection failed: " + e.getCause(), e.getCause());
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("Input injection failed: " + e, e);
        }
    }
}
```

- [ ] **Step 3: Create `server/src/main/java/com/deskbridge/server/PointerSpike.java`**

Diagnostic kept in the repo: re-run it on any new device or Android version before trusting injection.

```java
package com.deskbridge.server;

/** Run on a device via scripts/run_on_device.sh. Watch the screen: pointer, click, scroll, Back. */
public final class PointerSpike {
    public static void main(String[] args) throws Exception {
        InputInjector injector = new InputInjector();
        DisplayHelper.Size size = DisplayHelper.query();
        System.out.println("display " + size.width + "x" + size.height + " rotation " + size.rotation);
        float cx = size.width / 2f;
        float cy = size.height / 2f;

        System.out.println("1/4 hover sweep: a mouse pointer should be visible and move diagonally");
        for (int i = 0; i <= 120; i++) {
            injector.hover((size.width - 1) * i / 120f, (size.height - 1) * i / 120f);
            Thread.sleep(16);
        }

        System.out.println("2/4 click at the center");
        injector.hover(cx, cy);
        Thread.sleep(300);
        injector.button(1, true, cx, cy);
        Thread.sleep(80);
        injector.button(1, false, cx, cy);
        Thread.sleep(500);

        System.out.println("3/4 scroll down by 3 lines");
        injector.scroll(cx, cy, 0f, -3f);
        Thread.sleep(500);

        System.out.println("4/4 Back key");
        injector.key(4, 0, 0);
        injector.key(4, 1, 0);
        Thread.sleep(300);

        injector.hoverExit(cx, cy);
        System.out.println("done");
    }
}
```

- [ ] **Step 4: Create `scripts/run_on_device.sh`**

```bash
#!/usr/bin/env bash
# Usage: scripts/run_on_device.sh <MainClass> [args...]   (honors ANDROID_SERIAL)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAR="$ROOT/server/build/deskbridge-server.jar"
CLASS="${1:?usage: run_on_device.sh <MainClass> [args...]}"
shift

"$ROOT/scripts/build_server.sh" >/dev/null
adb push "$JAR" /data/local/tmp/deskbridge-server.jar >/dev/null
adb shell "CLASSPATH=/data/local/tmp/deskbridge-server.jar exec app_process / $CLASS $*"
```

- [ ] **Step 5: Build, run the spike on a device, apply the gate**

Run: `scripts/run_on_device.sh com.deskbridge.server.PointerSpike`
Expected: console prints the four stages, and on the phone you observe all of:
1. a **visible mouse pointer** that moves during the sweep (a screenshot with `adb exec-out screencap -p > /tmp/spike.png` while it runs also counts as evidence if it shows the pointer),
2. the click lands (e.g. opens something under the center),
3. the content scrolls,
4. Back is performed.

Record device, Android version and result in the commit message. Test at least one Pixel/AOSP-like device and one Samsung or Xiaomi device (Xiaomi: enable "USB debugging (Security settings)").

**Gate decision:**
- Stages 1–4 pass → continue with Task 3.
- Pointer not visible, or injection throws (`SecurityException`, `NoSuchMethodException`) → **stop**. Amend this plan: replace `InputInjector` with a UHID-backed injector (virtual HID mouse + keyboard through `/dev/uhid`, the approach scrcpy documents for a visible device pointer) behind the same method set (`hover`, `button`, `scroll`, `key`, ...), and re-run this step. If UHID is also blocked, evaluate AOA over USB from the Mac. The protocol, `PointerState`, and all Mac tasks stay unchanged except that UHID needs HID usage codes in `KeyMapper`.

**Gate result (Galaxy Note10 Lite SM-N770F, Android 13, 2026-10-12):** injection works (a click opened Calendar, Back and scroll acted), but Android's system pointer is **not** drawn or moved by injected events (SurfaceFlinger `Sprite` layer: hidden, no buffer, position unchanged). Decision: keep absolute injection and draw the pointer ourselves with a shell-owned `SurfaceControl` layer (`CursorOverlay`, verified by screenshot). UHID stays a fallback only. `PointerSpike` now shows the overlay.

- [ ] **Step 6: Commit**

```bash
git add scripts/ server/
git commit -m "feat(server): InputInjector, DisplayHelper and PointerSpike gate (<device>, Android <ver>: <result>)"
```

---

### Task 3: `ServerMain` (abstract socket, token, heartbeat) and dev scripts

**Files:**
- Create: `server/src/main/java/com/deskbridge/server/ServerMain.java`
- Create: `scripts/run_server_dev.sh`

**Interfaces:**
- Consumes: Mac connection via `adb forward tcp:0 localabstract:<name>`; args `<socketName> <token>`.
- Produces: one session: validates `HELLO`, replies `HELLO_OK`, injects events, sends `EXIT`/`PONG`, then exits.

- [ ] **Step 1: Create `server/src/main/java/com/deskbridge/server/ServerMain.java`**

```java
package com.deskbridge.server;

import android.net.LocalServerSocket;
import android.net.LocalSocket;

import com.deskbridge.server.protocol.PacketType;
import com.deskbridge.server.protocol.ProtocolDecoder;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One session per process: accept one host, serve it, exit.
 * Usage: app_process / com.deskbridge.server.ServerMain <socketName> <token>
 */
public final class ServerMain {
    private static final long ACCEPT_TIMEOUT_MS = 15_000;
    private static final int READ_TIMEOUT_MS = 6_000; // the host pings every 2 s

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("usage: ServerMain <socketName> <token>");
            System.exit(2);
        }
        int exitCode = 1;
        try {
            run(args[0], args[1]);
            exitCode = 0;
        } catch (Throwable t) {
            System.err.println("[DeskBridge] session failed: " + t);
            t.printStackTrace();
        }
        System.exit(exitCode);
    }

    private static void run(String socketName, String token) throws Exception {
        InputInjector injector = new InputInjector();
        AtomicBoolean accepted = new AtomicBoolean(false);

        try (LocalServerSocket server = new LocalServerSocket(socketName)) {
            Thread watchdog = new Thread(() -> {
                try {
                    Thread.sleep(ACCEPT_TIMEOUT_MS);
                } catch (InterruptedException e) {
                    return;
                }
                if (!accepted.get()) {
                    System.err.println("[DeskBridge] no host connected, exiting");
                    System.exit(1);
                }
            });
            watchdog.setDaemon(true);
            watchdog.start();

            try (LocalSocket socket = server.accept()) {
                accepted.set(true);
                serve(socket, token, injector);
            }
        }
    }

    private static void serve(LocalSocket socket, String token, InputInjector injector) throws Exception {
        socket.setSoTimeout(READ_TIMEOUT_MS);
        DataInputStream in = new DataInputStream(new BufferedInputStream(socket.getInputStream(), 4096));
        DataOutputStream out = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream(), 256));

        String received = ProtocolDecoder.readHello(in);
        if (!MessageDigest.isEqual(
                received.getBytes(StandardCharsets.US_ASCII), token.getBytes(StandardCharsets.US_ASCII))) {
            throw new SecurityException("bad token");
        }

        DisplayHelper.Size size = DisplayHelper.query();
        out.writeByte(PacketType.HELLO_OK);
        out.writeInt(size.width);
        out.writeInt(size.height);
        out.writeInt(size.rotation);
        out.flush();
        System.out.println("[DeskBridge] host connected, display " + size.width + "x" + size.height);

        PointerState pointer = new PointerState();
        ProtocolDecoder decoder = new ProtocolDecoder(new Handler(injector, pointer, out));
        try {
            while (decoder.processNext(in)) {
                // loop until EOF
            }
        } finally {
            injector.releaseAll(pointer.x(), pointer.y());
        }
    }

    /** Runs on the single session thread, so writes to `out` need no locking. */
    private static final class Handler implements ProtocolDecoder.Listener {
        private final InputInjector injector;
        private final PointerState pointer;
        private final DataOutputStream out;

        Handler(InputInjector injector, PointerState pointer, DataOutputStream out) {
            this.injector = injector;
            this.pointer = pointer;
            this.out = out;
        }

        @Override
        public void onEnter(int edge, float along) {
            try {
                DisplayHelper.Size size = DisplayHelper.query(); // re-read: rotation may have changed
                pointer.enter(size.width, size.height, edge, along);
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("display query failed", e);
            }
            injector.hover(pointer.x(), pointer.y());
        }

        @Override
        public void onLeave() {
            if (pointer.isEntered()) {
                endVisit();
            }
        }

        @Override
        public void onMouseMoveRel(float dx, float dy) throws IOException {
            if (!pointer.isEntered()) {
                return;
            }
            if (pointer.moveBy(dx, dy)) {
                injector.releaseAll(pointer.x(), pointer.y());
                injector.hoverExit(pointer.x(), pointer.y());
                out.writeByte(PacketType.EXIT);
                out.writeFloat(pointer.along());
                out.flush();
            } else {
                injector.hover(pointer.x(), pointer.y());
            }
        }

        @Override
        public void onMouseButton(int button, int action) {
            if (pointer.isEntered()) {
                injector.button(button, action == 0, pointer.x(), pointer.y());
            }
        }

        @Override
        public void onMouseScroll(float h, float v) {
            if (pointer.isEntered()) {
                injector.scroll(pointer.x(), pointer.y(), h, v);
            }
        }

        @Override
        public void onKeyEvent(int keyCode, int action, int metaState) {
            if (pointer.isEntered()) {
                injector.key(keyCode, action, metaState);
            }
        }

        @Override
        public void onPing() throws IOException {
            out.writeByte(PacketType.PONG);
            out.flush();
        }

        private void endVisit() {
            injector.releaseAll(pointer.x(), pointer.y());
            injector.hoverExit(pointer.x(), pointer.y());
            pointer.leave();
        }
    }
}
```

- [ ] **Step 2: Create `scripts/run_server_dev.sh`**

```bash
#!/usr/bin/env bash
# Runs ServerMain on the device with a fresh socket name/token and prints the forwarded port.
# The Mac app does the same thing itself (ServerLauncher); this is for debugging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="deskbridge-$(openssl rand -hex 4)"
TOKEN="$(openssl rand -hex 16)"

"$ROOT/scripts/build_server.sh" >/dev/null
adb push "$ROOT/server/build/deskbridge-server.jar" /data/local/tmp/deskbridge-server.jar >/dev/null
PORT="$(adb forward tcp:0 "localabstract:$NAME")"
trap 'adb forward --remove "tcp:$PORT" >/dev/null 2>&1 || true' EXIT

echo "port=$PORT token=$TOKEN"
adb shell "CLASSPATH=/data/local/tmp/deskbridge-server.jar exec app_process / com.deskbridge.server.ServerMain $NAME $TOKEN"
```

- [ ] **Step 3: Build and run unit tests**

Run: `chmod +x scripts/*.sh && scripts/build_server.sh && scripts/test_server.sh`
Expected: build succeeds; `OK 12 tests`.

- [ ] **Step 4: Commit**

```bash
git add scripts/ server/
git commit -m "feat(server): single-session ServerMain over abstract socket with token and heartbeat timeout"
```

---

### Task 4: Mac package and protocol codec

**Files:**
- Create: `mac/Package.swift`
- Create: `mac/Sources/DeskBridgeCore/Protocol/Packets.swift`
- Create: `mac/Tests/DeskBridgeCoreTests/PacketsTests.swift`
- Create: `mac/Sources/DeskBridge/DeskBridgeApp.swift` (temporary stub so the package builds; replaced in Task 10)

**Interfaces:**
- Produces: `ProtocolEncoder` (Mac→Android packets), `ServerPacketParser` (incremental, handles split reads), `ServerPacket`, `ProtocolEncoder.makeToken()`.

- [ ] **Step 1: Create `mac/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskBridge", targets: ["DeskBridge"]),
    ],
    targets: [
        .target(name: "DeskBridgeCore", path: "Sources/DeskBridgeCore"),
        .executableTarget(
            name: "DeskBridge",
            dependencies: ["DeskBridgeCore"],
            path: "Sources/DeskBridge"
        ),
        .testTarget(
            name: "DeskBridgeCoreTests",
            dependencies: ["DeskBridgeCore"],
            path: "Tests/DeskBridgeCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Create `mac/Sources/DeskBridge/DeskBridgeApp.swift` (temporary stub)**

```swift
import SwiftUI

@main
struct DeskBridgeApp: App {
    var body: some Scene {
        MenuBarExtra("DeskBridge", systemImage: "display") {
            Text("DeskBridge")
        }
    }
}
```

- [ ] **Step 3: Write failing tests `mac/Tests/DeskBridgeCoreTests/PacketsTests.swift`**

```swift
@testable import DeskBridgeCore
import Foundation
import Testing

struct PacketsTests {
    @Test func encodesHello() {
        let token = String(repeating: "a", count: 32)
        let data = ProtocolEncoder.hello(token: token)
        #expect(data.count == 34)
        #expect(Array(data.prefix(2)) == [0x01, 0x01])
        #expect(String(decoding: data.dropFirst(2), as: UTF8.self) == token)
    }

    @Test func encodesEnterAndLeave() {
        let data = ProtocolEncoder.enter(edge: .right, along: 0.5)
        #expect(Array(data) == [0x04, 0x01, 0x3F, 0x00, 0x00, 0x00])
        #expect(Array(ProtocolEncoder.leave()) == [0x06])
    }

    @Test func encodesMoveRelBigEndian() {
        let data = ProtocolEncoder.moveRel(dx: 100, dy: -2)
        #expect(Array(data) == [0x11, 0x42, 0xC8, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00])
    }

    @Test func encodesButtonScrollKey() {
        #expect(Array(ProtocolEncoder.button(2, down: true)) == [0x12, 0x02, 0x00])
        #expect(Array(ProtocolEncoder.button(2, down: false)) == [0x12, 0x02, 0x01])
        #expect(ProtocolEncoder.scroll(h: 0, v: -1).count == 9)
        let key = ProtocolEncoder.key(code: 29, down: false, meta: 0x1000)
        #expect(Array(key) == [0x20, 0, 0, 0, 29, 0x01, 0, 0, 0x10, 0x00])
    }

    @Test func tokenIs32HexChars() {
        let token = ProtocolEncoder.makeToken()
        #expect(token.count == 32)
        let allHex = token.allSatisfy { $0.isHexDigit }
        #expect(allHex)
        #expect(token != ProtocolEncoder.makeToken())
    }

    @Test func parsesHelloOKSplitAcrossReads() throws {
        var parser = ServerPacketParser()
        let bytes: [UInt8] = [0x02, 0, 0, 4, 56, 0, 0, 9, 96, 0, 0, 0, 1]
        #expect(try parser.feed(Data(bytes[0 ..< 5])).isEmpty)
        let packets = try parser.feed(Data(bytes[5...]))
        #expect(packets == [.helloOK(width: 1080, height: 2400, rotation: 1)])
    }

    @Test func parsesExitAndPongInOneRead() throws {
        var parser = ServerPacketParser()
        let packets = try parser.feed(Data([0x05, 0x3F, 0x00, 0x00, 0x00, 0xFF]))
        #expect(packets == [.exit(along: 0.5), .pong])
    }

    @Test func unknownPacketThrows() {
        var parser = ServerPacketParser()
        #expect(throws: ProtocolError.unknownPacket(0x7E)) {
            try parser.feed(Data([0x7E]))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd mac && swift test`
Expected: compile failure (`ProtocolEncoder` not found).

- [ ] **Step 5: Create `mac/Sources/DeskBridgeCore/Protocol/Packets.swift`**

```swift
import Foundation

public enum PacketType: UInt8, Sendable {
    case hello = 0x01
    case helloOK = 0x02
    case enter = 0x04
    case exit = 0x05
    case leave = 0x06
    case mouseMoveRel = 0x11
    case mouseButton = 0x12
    case mouseScroll = 0x13
    case keyEvent = 0x20
    case ping = 0xFE
    case pong = 0xFF
}

/// Edge of the Android display on which the pointer appears.
public enum AndroidEdge: UInt8, Sendable {
    case left = 0
    case right = 1
}

public enum ProtocolEncoder {
    public static let version: UInt8 = 1
    public static let tokenLength = 32

    /// 16 random bytes as 32 lowercase hex characters.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 16)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    public static func hello(token: String) -> Data {
        var data = Data([PacketType.hello.rawValue, version])
        data.append(contentsOf: Array(token.utf8))
        return data
    }

    public static func enter(edge: AndroidEdge, along: Float) -> Data {
        var data = Data([PacketType.enter.rawValue, edge.rawValue])
        data.appendBE(along)
        return data
    }

    public static func leave() -> Data {
        Data([PacketType.leave.rawValue])
    }

    public static func moveRel(dx: Float, dy: Float) -> Data {
        var data = Data([PacketType.mouseMoveRel.rawValue])
        data.appendBE(dx)
        data.appendBE(dy)
        return data
    }

    /// `button` is an Android MotionEvent.BUTTON_* bit (1 primary, 2 secondary, 4 tertiary).
    public static func button(_ button: UInt8, down: Bool) -> Data {
        Data([PacketType.mouseButton.rawValue, button, down ? 0 : 1])
    }

    public static func scroll(h: Float, v: Float) -> Data {
        var data = Data([PacketType.mouseScroll.rawValue])
        data.appendBE(h)
        data.appendBE(v)
        return data
    }

    /// `code` and `meta` are Android KeyEvent values.
    public static func key(code: Int32, down: Bool, meta: Int32) -> Data {
        var data = Data([PacketType.keyEvent.rawValue])
        data.appendBE(code)
        data.append(down ? 0 : 1)
        data.appendBE(meta)
        return data
    }

    public static func ping() -> Data {
        Data([PacketType.ping.rawValue])
    }
}

public enum ServerPacket: Equatable, Sendable {
    case helloOK(width: Int32, height: Int32, rotation: Int32)
    case exit(along: Float)
    case pong
}

public enum ProtocolError: Error, Equatable {
    case unknownPacket(UInt8)
}

/// Incremental parser for the Android→Mac stream; tolerates packets split across reads.
public struct ServerPacketParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ServerPacket] {
        buffer.append(contentsOf: data)
        var packets: [ServerPacket] = []
        while let type = buffer.first {
            switch PacketType(rawValue: type) {
            case .helloOK:
                guard buffer.count >= 13 else { return packets }
                packets.append(.helloOK(
                    width: Int32(bitPattern: word(at: 1)),
                    height: Int32(bitPattern: word(at: 5)),
                    rotation: Int32(bitPattern: word(at: 9))
                ))
                buffer.removeFirst(13)
            case .exit:
                guard buffer.count >= 5 else { return packets }
                packets.append(.exit(along: Float(bitPattern: word(at: 1))))
                buffer.removeFirst(5)
            case .pong:
                packets.append(.pong)
                buffer.removeFirst(1)
            default:
                throw ProtocolError.unknownPacket(type)
            }
        }
        return packets
    }

    private func word(at index: Int) -> UInt32 {
        (UInt32(buffer[index]) << 24) | (UInt32(buffer[index + 1]) << 16)
            | (UInt32(buffer[index + 2]) << 8) | UInt32(buffer[index + 3])
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: Int32) {
        appendBE(UInt32(bitPattern: value))
    }

    mutating func appendBE(_ value: Float) {
        appendBE(value.bitPattern)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd mac && swift test`
Expected: all `PacketsTests` pass.

- [ ] **Step 7: Commit**

```bash
git add mac/
git commit -m "feat(mac): SwiftPM package with core library and protocol codec"
```

---

### Task 5: `ADBBridge` and `ServerLauncher`

**Files:**
- Create: `mac/Sources/DeskBridgeCore/Network/ADBBridge.swift`
- Create: `mac/Sources/DeskBridgeCore/Network/ServerLauncher.swift`
- Create: `mac/Sources/DeskBridgeCore/Config/ServerJar.swift`
- Create: `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift`

**Interfaces:**
- Consumes: `adb` found via `$ADB`, `$ANDROID_HOME`, `~/Library/Android/sdk`, Homebrew paths (a GUI app has no useful `$PATH`).
- Produces: `ADBBridge.devices()`, `LaunchedServer` (port, token, process, `lastError`, `terminate()`), `ServerJar.locate()`.

- [ ] **Step 1: Write failing test `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift`**

```swift
@testable import DeskBridgeCore
import Testing

struct ADBBridgeTests {
    @Test func parsesDeviceList() {
        let output = """
        * daemon started successfully *
        List of devices attached
        emulator-5554\tdevice
        RFC840\tunauthorized
        192.168.1.50:5555\tdevice
        R5CT\toffline

        """
        let devices = ADBBridge.parseDevices(output)
        #expect(devices.map(\.serial) == ["emulator-5554", "RFC840", "192.168.1.50:5555", "R5CT"])
        #expect(devices.filter(\.isReady).map(\.serial) == ["emulator-5554", "192.168.1.50:5555"])
    }

    @Test func parsesEmptyList() {
        #expect(ADBBridge.parseDevices("List of devices attached\n\n").isEmpty)
    }

    @Test func parsesForwardPort() throws {
        #expect(try ADBBridge.parseForwardPort("54321\n") == 54321)
        #expect(throws: ADBError.self) { try ADBBridge.parseForwardPort("error: closed") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: compile failure (`ADBBridge` not found).

- [ ] **Step 3: Create `mac/Sources/DeskBridgeCore/Network/ADBBridge.swift`**

```swift
import Foundation

public struct AdbDevice: Equatable, Sendable {
    public let serial: String
    public let state: String
    public var isReady: Bool {
        state == "device"
    }
}

public enum ADBError: Error, CustomStringConvertible {
    case adbNotFound
    case commandFailed(String)
    case badForwardOutput(String)

    public var description: String {
        switch self {
        case .adbNotFound: "adb not found. Install Android platform-tools or set ANDROID_HOME."
        case let .commandFailed(output): "adb failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .badForwardOutput(output): "Unexpected adb forward output: \(output)"
        }
    }
}

public struct ADBBridge: Sendable {
    public let adbPath: String

    public init(adbPath: String? = nil) throws {
        guard let path = adbPath ?? Self.locate() else { throw ADBError.adbNotFound }
        self.adbPath = path
    }

    public static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let adb = env["ADB"] {
            candidates.append(adb)
        }
        if let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] {
            candidates.append(sdk + "/platform-tools/adb")
        }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Parsing (pure, unit-tested)

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            return AdbDevice(serial: String(parts[0]), state: String(parts[1]))
        }
    }

    public static func parseForwardPort(_ output: String) throws -> Int {
        guard let port = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            throw ADBError.badForwardOutput(output)
        }
        return port
    }

    // MARK: - Commands

    public func devices() throws -> [AdbDevice] {
        try Self.parseDevices(run(["devices"]))
    }

    public func push(serial: String, local: URL, remote: String) throws {
        _ = try run(["-s", serial, "push", local.path, remote])
    }

    /// Lets adb pick a free local port and returns it.
    public func forward(serial: String, abstractSocket: String) throws -> Int {
        try Self.parseForwardPort(run(["-s", serial, "forward", "tcp:0", "localabstract:\(abstractSocket)"]))
    }

    public func removeForward(serial: String, port: Int) {
        _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"])
    }

    /// Long-lived `adb shell` process; stderr is piped so the caller can surface server errors.
    public func spawnShell(serial: String, command: String) throws -> (process: Process, stderr: Pipe) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        return (process, stderr)
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile() // read before wait: avoids a full-pipe deadlock
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ADBError.commandFailed(text) }
        return text
    }
}
```

- [ ] **Step 4: Create `mac/Sources/DeskBridgeCore/Network/ServerLauncher.swift`**

```swift
import Foundation
import os

/// A running deskbridge-server on one device plus the adb forward that reaches it.
public final class LaunchedServer: @unchecked Sendable {
    public let serial: String
    public let port: Int
    public let token: String
    private let adb: ADBBridge
    private let process: Process
    private let errorLog = OSAllocatedUnfairLock(initialState: "")

    init(serial: String, port: Int, token: String, adb: ADBBridge, process: Process, stderr: Pipe) {
        self.serial = serial
        self.port = port
        self.token = token
        self.adb = adb
        self.process = process
        let log = errorLog
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            log.withLock { $0 = String(($0 + text).suffix(2000)) }
        }
    }

    public var isRunning: Bool {
        process.isRunning
    }

    /// Last stderr output of the server (e.g. a SecurityException from input injection).
    public var lastError: String {
        errorLog.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        adb.removeForward(serial: serial, port: port)
    }
}

extension ADBBridge {
    static let remoteJar = "/data/local/tmp/deskbridge-server.jar"

    /// Pushes the jar, forwards a random abstract socket and starts the server.
    /// The server may need a moment to listen: callers retry the connection.
    public func launchServer(serial: String, jar: URL) throws -> LaunchedServer {
        let socketName = "deskbridge-" + ProtocolEncoder.makeToken().prefix(8)
        let token = ProtocolEncoder.makeToken()

        try push(serial: serial, local: jar, remote: Self.remoteJar)
        let port = try forward(serial: serial, abstractSocket: socketName)
        do {
            let command = "CLASSPATH=\(Self.remoteJar) exec app_process / com.deskbridge.server.ServerMain \(socketName) \(token)"
            let (process, stderr) = try spawnShell(serial: serial, command: command)
            return LaunchedServer(serial: serial, port: port, token: token, adb: self, process: process, stderr: stderr)
        } catch {
            removeForward(serial: serial, port: port)
            throw error
        }
    }
}
```

- [ ] **Step 5: Create `mac/Sources/DeskBridgeCore/Config/ServerJar.swift`**

```swift
import Foundation

public enum ServerJar {
    /// App bundle resource, `$DESKBRIDGE_SERVER_JAR`, or the dev build output next to `mac/`.
    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "deskbridge-server", withExtension: "jar") {
            candidates.append(bundled)
        }
        if let path = ProcessInfo.processInfo.environment["DESKBRIDGE_SERVER_JAR"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath + "/../server/build/deskbridge-server.jar"))
        return candidates.first { fm.fileExists(atPath: $0.path) }?.standardizedFileURL
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add mac/
git commit -m "feat(mac): ADBBridge and ServerLauncher (random abstract socket + token per session)"
```

---

### Task 6: `Connection` (Network.framework) and `MoveCoalescer`

**Files:**
- Create: `mac/Sources/DeskBridgeCore/Network/Connection.swift`
- Create: `mac/Sources/DeskBridgeCore/Core/MoveCoalescer.swift`
- Create: `mac/Tests/DeskBridgeCoreTests/MoveCoalescerTests.swift`

**Interfaces:**
- Produces: `Connection` (TCP_NODELAY, callbacks on the queue you pass, `send(_:completion:)`); `MoveCoalescer` (accumulate deltas while a send is in flight, so a busy link adds no latency when idle and never builds a backlog).

- [ ] **Step 1: Write failing tests `mac/Tests/DeskBridgeCoreTests/MoveCoalescerTests.swift`**

```swift
@testable import DeskBridgeCore
import Testing

struct MoveCoalescerTests {
    @Test func sendsImmediatelyWhenIdle() {
        var c = MoveCoalescer()
        let first = c.add(dx: 3, dy: -1)
        #expect(first?.dx == 3 && first?.dy == -1)
    }

    @Test func accumulatesWhileInFlightThenFlushesOnCompletion() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 1)
        #expect(c.add(dx: 2, dy: 0) == nil)
        #expect(c.add(dx: 3, dy: 5) == nil)
        let next = c.sendCompleted()
        #expect(next?.dx == 5 && next?.dy == 5)
        #expect(c.sendCompleted() == nil)
    }

    @Test func idleAgainAfterCompletionWithNothingPending() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 0)
        #expect(c.sendCompleted() == nil)
        #expect(c.add(dx: 4, dy: 4) != nil)
    }

    @Test func flushForcesPendingDeltaOut() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 0)
        _ = c.add(dx: 7, dy: 2)
        let flushed = c.flush()
        #expect(flushed?.dx == 7 && flushed?.dy == 2)
        #expect(c.flush() == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter MoveCoalescerTests`
Expected: compile failure.

- [ ] **Step 3: Create `mac/Sources/DeskBridgeCore/Core/MoveCoalescer.swift`**

```swift
/// Merges mouse deltas while a send is still in flight. Not thread-safe: use from one queue.
public struct MoveCoalescer: Sendable {
    public struct Delta: Equatable, Sendable {
        public let dx: Float
        public let dy: Float
    }

    private var pendingX: Float = 0
    private var pendingY: Float = 0
    private var inFlight = 0

    public init() {}

    /// Returns the delta to send now, or nil if a send is in flight (the delta is kept).
    public mutating func add(dx: Float, dy: Float) -> Delta? {
        pendingX += dx
        pendingY += dy
        return inFlight == 0 ? take() : nil
    }

    /// Call when a previously returned delta was handed to the network. Returns the next delta, if any.
    public mutating func sendCompleted() -> Delta? {
        inFlight = max(0, inFlight - 1)
        return inFlight == 0 ? take() : nil
    }

    /// Takes the pending delta even if a send is in flight (before a button/key, to keep ordering).
    public mutating func flush() -> Delta? {
        take()
    }

    private mutating func take() -> Delta? {
        guard pendingX != 0 || pendingY != 0 else { return nil }
        let delta = Delta(dx: pendingX, dy: pendingY)
        pendingX = 0
        pendingY = 0
        inFlight += 1
        return delta
    }
}
```

- [ ] **Step 4: Create `mac/Sources/DeskBridgeCore/Network/Connection.swift`**

```swift
import Foundation
import Network

/// TCP connection to the forwarded server port. All callbacks run on `queue`.
public final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    /// Set before `start()`.
    public var onReady: (@Sendable () -> Void)?
    public var onData: (@Sendable (Data) -> Void)?
    /// Fires once: failure, refusal, EOF or `cancel()`.
    public var onClosed: (@Sendable () -> Void)?

    public init(port: UInt16, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // mouse deltas are tiny; Nagle would batch them
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? 1,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady?()
                receiveLoop()
            case .failed, .cancelled, .waiting: // .waiting == connection refused; the caller retries
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data, completion: (@Sendable () -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
            completion?()
        })
    }

    public func cancel() {
        queue.async { self.close() }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                onData?(data)
            }
            if isComplete || error != nil {
                close()
            } else {
                receiveLoop()
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed?()
    }
}
```

- [ ] **Step 5: Run tests and build**

Run: `cd mac && swift test --filter MoveCoalescerTests && swift build`
Expected: PASS, build complete.

- [ ] **Step 6: Commit**

```bash
git add mac/
git commit -m "feat(mac): Connection with TCP_NODELAY and backpressure-aware MoveCoalescer"
```

---

### Task 7: `KeyMapper` and `EdgeDetector`

**Files:**
- Create: `mac/Sources/DeskBridgeCore/Core/KeyMapper.swift`
- Create: `mac/Sources/DeskBridgeCore/Core/EdgeDetector.swift`
- Create: `mac/Tests/DeskBridgeCoreTests/KeyMapperTests.swift`
- Create: `mac/Tests/DeskBridgeCoreTests/EdgeDetectorTests.swift`

**Interfaces:**
- Produces: `KeyMapper.androidKeyCode(forMacKeyCode:)` (nil for unmapped keys; never forwards raw Mac codes), `KeyMapper.androidMeta(forFlags:)`, `KeyMapper.isReleaseChord`; `EdgeDetector.crossing`, `returnPoint`, `currentBounds`.

- [ ] **Step 1: Write failing tests**

Create `mac/Tests/DeskBridgeCoreTests/KeyMapperTests.swift`:

```swift
import Carbon.HIToolbox
import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct KeyMapperTests {
    @Test func mapsLettersDigitsAndControls() {
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_A)) == 29)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_S)) == 47) // not SOFT_LEFT(1)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_Z)) == 54)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_0)) == 7)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Return)) == 66)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Delete)) == 67)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Escape)) == 111)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_LeftArrow)) == 21)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_F1)) == 131)
    }

    @Test func unmappedKeysAreDropped() {
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Function)) == nil)
    }

    @Test func tableHasNoDuplicateAndroidCodes() {
        let codes = KeyMapper.table.values
        #expect(Set(codes).count == codes.count)
    }

    @Test func commandBecomesControl() {
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskCommand.rawValue) == 0x1000 | 0x2000)
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskShift.rawValue) == 0x1 | 0x40)
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskAlternate.rawValue) == 0x2 | 0x10)
        #expect(KeyMapper.androidMeta(forFlags: 0) == 0)
    }

    @Test func releaseChord() {
        let chord = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        #expect(KeyMapper.isReleaseChord(keyCode: UInt16(kVK_Escape), flags: chord))
        #expect(!KeyMapper.isReleaseChord(keyCode: UInt16(kVK_Escape), flags: CGEventFlags.maskCommand.rawValue))
        #expect(!KeyMapper.isReleaseChord(keyCode: UInt16(kVK_ANSI_A), flags: chord))
    }
}
```

Create `mac/Tests/DeskBridgeCoreTests/EdgeDetectorTests.swift`:

```swift
import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct EdgeDetectorTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func rightEdgeCrossingReportsAlong() throws {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        let along = d.crossing(at: CGPoint(x: 1511, y: 491), deltaX: 4)
        #expect(try along != nil && abs(#require(along) - 0.5) < 0.001)
    }

    @Test func noCrossingWhenMovingInwardOrAwayFromEdge() {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 1511, y: 100), deltaX: -4) == nil)
        #expect(d.crossing(at: CGPoint(x: 700, y: 100), deltaX: 4) == nil)
    }

    @Test func leftEdgeCrossing() {
        let d = EdgeDetector(edge: .left, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: -1) == 0)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: 1) == nil)
    }

    @Test func returnPointIsInsetFromTheEdge() {
        let right = EdgeDetector(edge: .right, bounds: bounds).returnPoint(along: 0.5)
        #expect(right.x == bounds.maxX - 12)
        let left = EdgeDetector(edge: .left, bounds: bounds).returnPoint(along: 0)
        #expect(left == CGPoint(x: 12, y: 0))
    }

    @Test func androidEntryEdgeIsOpposite() {
        #expect(ScreenEdge.right.androidEntryEdge == .left)
        #expect(ScreenEdge.left.androidEntryEdge == .right)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test --filter "KeyMapperTests|EdgeDetectorTests"`
Expected: compile failure.

- [ ] **Step 3: Create `mac/Sources/DeskBridgeCore/Core/KeyMapper.swift`**

```swift
import Carbon.HIToolbox
import CoreGraphics

public enum KeyMapper {
    public static let backKeyCode: Int32 = 4 // KEYCODE_BACK

    /// Mac virtual keycode -> Android KEYCODE_*. Keys not listed are not forwarded.
    static let table: [Int: Int32] = [
        kVK_ANSI_A: 29, kVK_ANSI_B: 30, kVK_ANSI_C: 31, kVK_ANSI_D: 32, kVK_ANSI_E: 33,
        kVK_ANSI_F: 34, kVK_ANSI_G: 35, kVK_ANSI_H: 36, kVK_ANSI_I: 37, kVK_ANSI_J: 38,
        kVK_ANSI_K: 39, kVK_ANSI_L: 40, kVK_ANSI_M: 41, kVK_ANSI_N: 42, kVK_ANSI_O: 43,
        kVK_ANSI_P: 44, kVK_ANSI_Q: 45, kVK_ANSI_R: 46, kVK_ANSI_S: 47, kVK_ANSI_T: 48,
        kVK_ANSI_U: 49, kVK_ANSI_V: 50, kVK_ANSI_W: 51, kVK_ANSI_X: 52, kVK_ANSI_Y: 53,
        kVK_ANSI_Z: 54,
        kVK_ANSI_0: 7, kVK_ANSI_1: 8, kVK_ANSI_2: 9, kVK_ANSI_3: 10, kVK_ANSI_4: 11,
        kVK_ANSI_5: 12, kVK_ANSI_6: 13, kVK_ANSI_7: 14, kVK_ANSI_8: 15, kVK_ANSI_9: 16,
        kVK_ANSI_Grave: 68, kVK_ANSI_Minus: 69, kVK_ANSI_Equal: 70,
        kVK_ANSI_LeftBracket: 71, kVK_ANSI_RightBracket: 72, kVK_ANSI_Backslash: 73,
        kVK_ANSI_Semicolon: 74, kVK_ANSI_Quote: 75, kVK_ANSI_Slash: 76,
        kVK_ANSI_Comma: 55, kVK_ANSI_Period: 56,
        kVK_Return: 66, kVK_Tab: 61, kVK_Space: 62, kVK_Delete: 67, kVK_ForwardDelete: 112,
        kVK_Escape: 111,
        kVK_LeftArrow: 21, kVK_RightArrow: 22, kVK_UpArrow: 19, kVK_DownArrow: 20,
        kVK_Home: 122, kVK_End: 123, kVK_PageUp: 92, kVK_PageDown: 93,
        kVK_F1: 131, kVK_F2: 132, kVK_F3: 133, kVK_F4: 134, kVK_F5: 135, kVK_F6: 136,
        kVK_F7: 137, kVK_F8: 138, kVK_F9: 139, kVK_F10: 140, kVK_F11: 141, kVK_F12: 142,
    ]

    public static func androidKeyCode(forMacKeyCode code: UInt16) -> Int32? {
        table[Int(code)]
    }

    /// Cmd and Ctrl both become Android Ctrl, so Cmd+C / Cmd+V work in Android apps.
    public static func androidMeta(forFlags rawFlags: UInt64) -> Int32 {
        let flags = CGEventFlags(rawValue: rawFlags)
        var meta: Int32 = 0
        if flags.contains(.maskShift) {
            meta |= 0x1 | 0x40
        } // META_SHIFT_ON | META_SHIFT_LEFT_ON
        if flags.contains(.maskAlternate) {
            meta |= 0x2 | 0x10
        } // META_ALT_ON | META_ALT_LEFT_ON
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            meta |= 0x1000 | 0x2000 // META_CTRL_ON | META_CTRL_LEFT_ON
        }
        return meta
    }

    /// ⌃⌥⌘⎋ hands control back to the Mac from any state.
    public static func isReleaseChord(keyCode: UInt16, flags rawFlags: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: rawFlags)
        return Int(keyCode) == kVK_Escape
            && flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }
}
```

- [ ] **Step 4: Create `mac/Sources/DeskBridgeCore/Core/EdgeDetector.swift`**

```swift
import CoreGraphics

/// Mac screen edge where the Android device "sits".
public enum ScreenEdge: Int, Sendable, CaseIterable {
    case left = 0
    case right = 1

    /// The Android edge the pointer appears on is the opposite one.
    public var androidEntryEdge: AndroidEdge {
        self == .right ? .left : .right
    }
}

public struct EdgeDetector: Sendable {
    public let edge: ScreenEdge
    /// Union of all displays in global coordinates, so moving between Mac displays never counts as an edge.
    public let bounds: CGRect

    private static let tolerance: CGFloat = 1.5

    public init(edge: ScreenEdge, bounds: CGRect) {
        self.edge = edge
        self.bounds = bounds
    }

    /// If the cursor sits on the configured edge and pushes outward, returns the normalized
    /// position (0...1) along that edge; otherwise nil.
    public func crossing(at point: CGPoint, deltaX: Double) -> Float? {
        switch edge {
        case .right: guard point.x >= bounds.maxX - Self.tolerance, deltaX > 0 else { return nil }
        case .left: guard point.x <= bounds.minX + Self.tolerance, deltaX < 0 else { return nil }
        }
        guard bounds.height > 0 else { return 0.5 }
        return Float(min(max((point.y - bounds.minY) / bounds.height, 0), 1))
    }

    /// Where to put the Mac cursor when control returns (slightly inside, so it does not re-trigger).
    public func returnPoint(along: Float, inset: CGFloat = 12) -> CGPoint {
        CGPoint(
            x: edge == .right ? bounds.maxX - inset : bounds.minX + inset,
            y: bounds.minY + CGFloat(along) * (bounds.height - 1)
        )
    }

    public static func currentBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test --filter "KeyMapperTests|EdgeDetectorTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add mac/
git commit -m "feat(mac): complete KeyMapper table, Cmd->Ctrl meta, release chord and EdgeDetector"
```

---

### Task 8: `InputCapturer` (event tap on its own thread) and `Settings`

**Files:**
- Create: `mac/Sources/DeskBridgeCore/Core/InputCapturer.swift`
- Create: `mac/Sources/DeskBridgeCore/Config/Settings.swift`

**Interfaces:**
- Consumes: `isRemote` closure (decides whether to swallow events), `onEvent` closure (receives `CapturedEvent`).
- Produces: `InputCapturer.start()` (throws if the tap cannot be created, i.e. missing permission), `stop()`; `Settings` (edge, right-click behavior, pointer speed, persisted).

- [ ] **Step 1: Create `mac/Sources/DeskBridgeCore/Core/InputCapturer.swift`**

```swift
import CoreGraphics
import Foundation

public enum MouseButton: Sendable {
    case left, right, other
}

public enum CapturedEvent: Sendable {
    case move(dx: Double, dy: Double, location: CGPoint)
    case button(MouseButton, down: Bool)
    case scroll(h: Double, v: Double)
    case key(code: UInt16, down: Bool, flags: UInt64)
}

public enum CaptureError: Error, CustomStringConvertible {
    case tapCreationFailed

    public var description: String {
        "Cannot capture input. Allow DeskBridge in System Settings > Privacy & Security > Accessibility (and Input Monitoring)."
    }
}

/// Active event tap on a dedicated thread. The callback only classifies events and hands them to
/// `onEvent`; it swallows them when `isRemote()` is true. Keep both closures cheap.
public final class InputCapturer: @unchecked Sendable {
    private let isRemote: @Sendable () -> Bool
    private let onEvent: @Sendable (CapturedEvent) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    public init(isRemote: @escaping @Sendable () -> Bool, onEvent: @escaping @Sendable (CapturedEvent) -> Void) {
        self.isRemote = isRemote
        self.onEvent = onEvent
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let types: [CGEventType] = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp,
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "deskbridge.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait() // the semaphore orders the writes to `tap` / `runLoop` before this read
        guard tap != nil else { throw CaptureError.tapCreationFailed }
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoop = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let remote = isRemote()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return pass

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            onEvent(.move(
                dx: event.getDoubleValueField(.mouseEventDeltaX),
                dy: event.getDoubleValueField(.mouseEventDeltaY),
                location: event.location
            ))
            return remote ? nil : pass

        case .leftMouseDown, .leftMouseUp:
            guard remote else { return pass }
            onEvent(.button(.left, down: type == .leftMouseDown))
            return nil

        case .rightMouseDown, .rightMouseUp:
            guard remote else { return pass }
            onEvent(.button(.right, down: type == .rightMouseDown))
            return nil

        case .otherMouseDown, .otherMouseUp:
            guard remote else { return pass }
            onEvent(.button(.other, down: type == .otherMouseDown))
            return nil

        case .scrollWheel:
            guard remote else { return pass }
            onEvent(.scroll(
                h: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                v: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            ))
            return nil

        case .keyDown, .keyUp:
            guard remote else { return pass }
            onEvent(.key(
                code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                down: type == .keyDown,
                flags: event.flags.rawValue
            ))
            return nil

        default:
            return pass
        }
    }
}

private func tapCallback(
    proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputCapturer>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
```

- [ ] **Step 2: Create `mac/Sources/DeskBridgeCore/Config/Settings.swift`**

```swift
import Foundation
import os

/// User settings, readable from any thread and persisted to UserDefaults.
public final class Settings: @unchecked Sendable {
    public struct Values: Equatable, Sendable {
        public var edge: ScreenEdge = .right
        /// true: right click sends Android Back; false: a real secondary button press.
        public var rightClickIsBack = true
        /// Mac points -> Android pixels multiplier for pointer deltas.
        public var pointerSpeed: Double = 2.0
    }

    private let lock: OSAllocatedUnfairLock<Values>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var values = Values()
        if let raw = defaults.object(forKey: "edge") as? Int, let edge = ScreenEdge(rawValue: raw) {
            values.edge = edge
        }
        if let back = defaults.object(forKey: "rightClickIsBack") as? Bool {
            values.rightClickIsBack = back
        }
        if let speed = defaults.object(forKey: "pointerSpeed") as? Double {
            values.pointerSpeed = speed
        }
        lock = OSAllocatedUnfairLock(initialState: values)
    }

    public var values: Values {
        get { lock.withLock { $0 } }
        set {
            lock.withLock { $0 = newValue }
            defaults.set(newValue.edge.rawValue, forKey: "edge")
            defaults.set(newValue.rightClickIsBack, forKey: "rightClickIsBack")
            defaults.set(newValue.pointerSpeed, forKey: "pointerSpeed")
        }
    }
}
```

- [ ] **Step 3: Verify compilation**

Run: `cd mac && swift build`
Expected: Build complete (Swift 6 mode, no concurrency errors).

- [ ] **Step 4: Commit**

```bash
git add mac/
git commit -m "feat(mac): event-tap InputCapturer on a dedicated thread and persisted Settings"
```

---

### Task 9: `DeviceSession` (Mac⇄Android state machine and wiring)

**Files:**
- Create: `mac/Sources/DeskBridgeCore/Core/DeviceSession.swift`

**Interfaces:**
- Consumes: `ADBBridge`, device `serial`, server jar `URL`, `Settings`.
- Produces: `DeviceSession` with `start()`, `stop()`, `onStateChange` (`.starting`, `.local`, `.remote`, `.ended(reason)`). Owns the server process, connection, heartbeat, event tap, cursor lock/hide and the release chord.

State rules (all on one serial queue; only `remoteFlag` is read from the tap thread):
- `.starting` → launch server, connect with retry (≤ 8 s) → `HELLO_OK` → start tap + heartbeat → `.local`.
- `.local`: moves are only inspected; at the configured edge pushing outward → send `ENTER`, freeze+hide cursor, `.remote`.
- `.remote`: deltas × `pointerSpeed` → coalesced `MOUSE_MOVE_REL`; buttons/scroll/keys forwarded (flush pending moves first); `EXIT` from the server or ⌃⌥⌘⎋ → `.local`.
- Any failure (disconnect, 6 s silence, server exit, tap failure) → release control, tear down, `.ended(reason)`.

- [ ] **Step 1: Create `mac/Sources/DeskBridgeCore/Core/DeviceSession.swift`**

```swift
import CoreGraphics
import Foundation
import os

public final class DeviceSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case local
        case remote
        case ended(reason: String)
    }

    /// Set before `start()`. Called on the session queue.
    public var onStateChange: (@Sendable (State) -> Void)?

    private static let connectTimeout: TimeInterval = 8
    private static let silenceTimeout: TimeInterval = 6
    private static let scrollSign: Float = 1 // flip to -1 if the manual check shows inverted scrolling

    private let adb: ADBBridge
    private let serial: String
    private let jar: URL
    private let settings: Settings
    private let queue = DispatchQueue(label: "deskbridge.session", qos: .userInteractive)
    private let remoteFlag = OSAllocatedUnfairLock(initialState: false)

    private var state: State = .starting {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    private var server: LaunchedServer?
    private var connection: Connection?
    private var capturer: InputCapturer?
    private var heartbeat: DispatchSourceTimer?
    private var parser = ServerPacketParser()
    private var coalescer = MoveCoalescer()
    private var detector = EdgeDetector(edge: .right, bounds: .zero)
    private var connectDeadline = Date()
    private var lastReceived = Date()

    public init(adb: ADBBridge, serial: String, jar: URL, settings: Settings) {
        self.adb = adb
        self.serial = serial
        self.jar = jar
        self.settings = settings
    }

    public func start() {
        queue.async { self.launch() }
    }

    public func stop() {
        queue.async { self.end("Stopped") }
    }

    // MARK: - Startup

    private func launch() {
        do {
            server = try adb.launchServer(serial: serial, jar: jar)
            connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
            connect()
        } catch {
            end("\(error)")
        }
    }

    private func connect() {
        guard let server, !isEnded else { return }
        parser = ServerPacketParser()
        let connection = Connection(port: UInt16(server.port), queue: queue)
        self.connection = connection
        let token = server.token
        connection.onReady = { [weak connection] in
            connection?.send(ProtocolEncoder.hello(token: token))
        }
        connection.onData = { [weak self] data in self?.received(data) }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            connectionClosed()
        }
        connection.start()
    }

    private func connectionClosed() {
        guard !isEnded else { return }
        if state == .starting, let server, server.isRunning, Date() < connectDeadline {
            // The server is probably still starting (or adb accepted before it listened): retry.
            queue.asyncAfter(deadline: .now() + 0.25) { self.connect() }
            return
        }
        let detail = server?.lastError ?? ""
        end(detail.isEmpty ? "Connection to the device was lost" : detail)
    }

    // MARK: - Incoming packets

    private func received(_ data: Data) {
        lastReceived = Date()
        do {
            for packet in try parser.feed(data) {
                switch packet {
                case .helloOK: startRunning()
                case let .exit(along): returnToMac(along: along, notifyServer: false)
                case .pong: break
                }
            }
        } catch {
            end("Protocol error: \(error)")
        }
    }

    private func startRunning() {
        guard state == .starting else { return }
        detector = EdgeDetector(edge: settings.values.edge, bounds: EdgeDetector.currentBounds())
        lastReceived = Date()

        let capturer = InputCapturer(
            isRemote: { [remoteFlag] in remoteFlag.withLock { $0 } },
            onEvent: { [weak self] event in
                guard let self else { return }
                queue.async { self.handle(event) }
            }
        )
        do {
            try capturer.start()
        } catch {
            end("\(error)")
            return
        }
        self.capturer = capturer

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        heartbeat = timer

        state = .local
    }

    private func tick() {
        guard !isEnded else { return }
        if Date().timeIntervalSince(lastReceived) > Self.silenceTimeout {
            end("The device stopped responding")
            return
        }
        connection?.send(ProtocolEncoder.ping())
        if state == .local {
            detector = EdgeDetector(edge: settings.values.edge, bounds: EdgeDetector.currentBounds())
        }
    }

    // MARK: - Captured input

    private func handle(_ event: CapturedEvent) {
        switch (state, event) {
        case let (.local, .move(dx, _, location)):
            if let along = detector.crossing(at: location, deltaX: dx) {
                enterRemote(along: along)
            }

        case let (.remote, .move(dx, dy, _)):
            let speed = settings.values.pointerSpeed
            if let delta = coalescer.add(dx: Float(dx * speed), dy: Float(dy * speed)) {
                transmit(delta)
            }

        case let (.remote, .button(button, down)):
            flushMoves()
            switch button {
            case .left: send(ProtocolEncoder.button(1, down: down))
            case .right where settings.values.rightClickIsBack:
                send(ProtocolEncoder.key(code: KeyMapper.backKeyCode, down: down, meta: 0))
            case .right: send(ProtocolEncoder.button(2, down: down))
            case .other: send(ProtocolEncoder.button(4, down: down))
            }

        case let (.remote, .scroll(h, v)):
            flushMoves()
            send(ProtocolEncoder.scroll(h: Float(h) * Self.scrollSign, v: Float(v) * Self.scrollSign))

        case let (.remote, .key(code, down, flags)):
            if down, KeyMapper.isReleaseChord(keyCode: code, flags: flags) {
                returnToMac(along: nil, notifyServer: true)
                return
            }
            guard let android = KeyMapper.androidKeyCode(forMacKeyCode: code) else { return }
            flushMoves()
            send(ProtocolEncoder.key(code: android, down: down, meta: KeyMapper.androidMeta(forFlags: flags)))

        default:
            break
        }
    }

    private func enterRemote(along: Float) {
        coalescer = MoveCoalescer()
        send(ProtocolEncoder.enter(edge: detector.edge.androidEntryEdge, along: along))
        remoteFlag.withLock { $0 = true }
        CGAssociateMouseAndMouseCursorPosition(0) // freeze the Mac cursor; deltas keep flowing
        CGDisplayHideCursor(CGMainDisplayID()) // best effort for a background app
        state = .remote
    }

    private func returnToMac(along: Float?, notifyServer: Bool) {
        guard state == .remote else { return }
        remoteFlag.withLock { $0 = false }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        if notifyServer {
            send(ProtocolEncoder.leave())
        }
        if let along {
            CGWarpMouseCursorPosition(detector.returnPoint(along: along))
        }
        state = .local
    }

    // MARK: - Sending

    private func send(_ data: Data) {
        connection?.send(data)
    }

    private func transmit(_ delta: MoveCoalescer.Delta) {
        connection?.send(ProtocolEncoder.moveRel(dx: delta.dx, dy: delta.dy)) { [weak self] in
            // Runs on the connection queue, which is the session queue.
            guard let self, let next = coalescer.sendCompleted() else { return }
            transmit(next)
        }
    }

    private func flushMoves() {
        if let delta = coalescer.flush() {
            transmit(delta)
        }
    }

    // MARK: - Teardown

    private var isEnded: Bool {
        if case .ended = state {
            return true
        }
        return false
    }

    private func end(_ reason: String) {
        guard !isEnded else { return }
        returnToMac(along: nil, notifyServer: false)
        heartbeat?.cancel()
        heartbeat = nil
        capturer?.stop()
        capturer = nil
        connection?.cancel()
        connection = nil
        server?.terminate()
        server = nil
        state = .ended(reason: reason)
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd mac && swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add mac/
git commit -m "feat(mac): DeviceSession state machine with edge transition, fail-safes and heartbeat"
```

---

### Task 10: Menu bar app, device discovery, packaging

**Files:**
- Replace: `mac/Sources/DeskBridge/DeskBridgeApp.swift`
- Create: `mac/Sources/DeskBridge/AppModel.swift`
- Create: `mac/Sources/DeskBridge/MenuBarView.swift`
- Create: `scripts/package_app.sh`

**Interfaces:**
- Consumes: `DeskBridgeCore`.
- Produces: a signed `build/DeskBridge.app` (menu bar only, no Dock icon) that finds a device, starts a session and shows status, edge, right-click mode and pointer speed.

- [ ] **Step 1: Create `mac/Sources/DeskBridge/AppModel.swift`**

```swift
import AppKit
import ApplicationServices
import DeskBridgeCore
import Observation

@MainActor @Observable
final class AppModel {
    var status = "Looking for a device…"
    var isActive = false
    var prefs: Settings.Values {
        didSet { settings.values = prefs }
    }

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private var session: DeviceSession?

    init() {
        prefs = settings.values
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { await discoveryLoop() }
    }

    private func discoveryLoop() async {
        while !Task.isCancelled {
            if session == nil {
                await tryStartSession()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func tryStartSession() async {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            status = "Allow DeskBridge in Privacy & Security > Accessibility"
            return
        }
        guard let jar = ServerJar.locate() else {
            status = "deskbridge-server.jar not found. Run scripts/build_server.sh"
            return
        }
        do {
            let adb = try ADBBridge()
            let devices = try await Task.detached { try adb.devices() }.value
            guard let device = devices.first(where: \.isReady) else {
                status = devices.isEmpty
                    ? "Connect an Android device with USB debugging"
                    : "Authorize this Mac on the device (\(devices[0].state))"
                return
            }
            status = "Connecting to \(device.serial)…"
            let session = DeviceSession(adb: adb, serial: device.serial, jar: jar, settings: settings)
            session.onStateChange = { [weak self] state in
                Task { @MainActor in self?.apply(state, serial: device.serial) }
            }
            self.session = session
            session.start()
        } catch {
            status = "\(error)"
        }
    }

    private func apply(_ state: DeviceSession.State, serial: String) {
        switch state {
        case .starting: status = "Connecting to \(serial)…"; isActive = false
        case .local: status = "Connected: \(serial)"; isActive = true
        case .remote: status = "Controlling \(serial) (⌃⌥⌘⎋ to release)"; isActive = true
        case let .ended(reason):
            status = reason
            isActive = false
            session = nil // the discovery loop starts a new session
        }
    }
}
```

- [ ] **Step 2: Create `mac/Sources/DeskBridge/MenuBarView.swift`**

```swift
import DeskBridgeCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(model.isActive ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(model.status).font(.headline).lineLimit(3)
            }

            Divider()

            Picker("Android is on the", selection: $model.prefs.edge) {
                Text("Left").tag(ScreenEdge.left)
                Text("Right").tag(ScreenEdge.right)
            }
            .pickerStyle(.segmented)

            Toggle("Right click = Back", isOn: $model.prefs.rightClickIsBack)

            VStack(alignment: .leading) {
                Text("Pointer speed \(model.prefs.pointerSpeed, specifier: "%.1f")×").font(.caption)
                Slider(value: $model.prefs.pointerSpeed, in: 0.5 ... 4)
            }

            Divider()

            Button("Quit DeskBridge") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
```

- [ ] **Step 3: Replace `mac/Sources/DeskBridge/DeskBridgeApp.swift`**

```swift
import SwiftUI

@main
struct DeskBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DeskBridge", systemImage: "display") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 4: Create `scripts/package_app.sh`**

```bash
#!/usr/bin/env bash
# Builds build/DeskBridge.app. Accessibility/Input Monitoring grants attach to the signed bundle,
# so use a stable identity to keep them across rebuilds:
#   CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/package_app.sh
# The default ad-hoc identity ("-") changes on every build and resets the permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DeskBridge.app"

"$ROOT/scripts/build_server.sh"
swift build -c release --package-path "$ROOT/mac"
BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)/DeskBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskBridge"
cp "$ROOT/server/build/deskbridge-server.jar" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.deskbridge.app</string>
  <key>CFBundleName</key><string>DeskBridge</string>
  <key>CFBundleExecutable</key><string>DeskBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
```

- [ ] **Step 5: Build, package, commit**

Run: `chmod +x scripts/*.sh && cd mac && swift build && cd .. && scripts/package_app.sh`
Expected: `Built .../build/DeskBridge.app`.

```bash
git add mac/ scripts/
git commit -m "feat(mac): menu bar app with device discovery, permission check and app packaging"
```

---

### Task 11: Device smoke test and acceptance checklist

**Files:**
- Create: `mac/Tests/DeskBridgeCoreTests/DeviceSmokeTests.swift`
- Modify: `README.md` (testing section)

**Interfaces:**
- Consumes: a real authorized device, built jar.
- Produces: automated proof of the Mac↔server path (launch, forward, token, handshake, bad-token rejection) and a manual checklist for the parts only a human can see.

- [ ] **Step 1: Create `mac/Tests/DeskBridgeCoreTests/DeviceSmokeTests.swift`**

Skipped unless `DESKBRIDGE_DEVICE=1`, so CI without a phone stays green.

```swift
@testable import DeskBridgeCore
import Foundation
import os
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_DEVICE"] != nil))
struct DeviceSmokeTests {
    @Test func handshakeSucceedsWithToken() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await handshake(port: server.port, token: server.token)
        guard case let .helloOK(width, height, _) = reply else {
            Issue.record("no HELLO_OK. server stderr: \(server.lastError)")
            return
        }
        #expect(width > 0 && height > 0)
    }

    @Test func wrongTokenIsRejected() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await handshake(port: server.port, token: ProtocolEncoder.makeToken(), within: 4)
        #expect(reply == nil)
    }

    // MARK: - helpers

    private func setup() throws -> (ADBBridge, String, URL) {
        let adb = try ADBBridge()
        let serial = try #require(try adb.devices().first(where: \.isReady)?.serial)
        let jar = try #require(ServerJar.locate())
        return (adb, serial, jar)
    }

    /// The server may not be listening yet, so a closed connection is retried until the deadline.
    private func handshake(port: Int, token: String, within seconds: Double = 8) async -> ServerPacket? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let packet = await attempt(port: port, token: token) {
                return packet
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func attempt(port: Int, token: String) async -> ServerPacket? {
        await withCheckedContinuation { continuation in
            let connection = Connection(port: UInt16(port), queue: DispatchQueue(label: "smoke"))
            let finished = OSAllocatedUnfairLock(initialState: false)
            let parser = OSAllocatedUnfairLock(initialState: ServerPacketParser())
            @Sendable func finish(_ packet: ServerPacket?) {
                guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: packet)
            }
            connection.onReady = { connection.send(ProtocolEncoder.hello(token: token)) }
            connection.onData = { data in
                if let first = parser.withLock({ try? $0.feed(data) })?.first {
                    finish(first)
                }
            }
            connection.onClosed = { finish(nil) }
            connection.start()
        }
    }
}
```

- [ ] **Step 2: Run the smoke test against a connected device**

Run: `scripts/build_server.sh && cd mac && DESKBRIDGE_DEVICE=1 swift test --filter DeviceSmokeTests`
Expected: both tests pass. Without the env var the suite is skipped.

- [ ] **Step 3: Manual acceptance (cannot be automated; record results in the PR/commit)**

Launch `build/DeskBridge.app` (grant Accessibility), connect a device, then check:
- [ ] Pushing the cursor through the configured Mac edge shows the pointer on Android at the matching height; pushing back through the same edge returns the Mac cursor at the matching height.
- [ ] Pointer moves smoothly; click, drag, long-press and text selection work.
- [ ] Scroll wheel/trackpad scrolls the right way (else flip `scrollSign` in `DeviceSession`).
- [ ] Right click = Back (and a real context menu with the toggle off).
- [ ] Typing letters, digits and punctuation; Cmd+C / Cmd+V / Cmd+A in a text field; arrows and Backspace.
- [ ] ⌃⌥⌘⎋ returns control instantly.
- [ ] Unplugging the cable frees the Mac cursor within ~6 s; replugging reconnects automatically.
- [ ] Mac cursor is hidden/frozen while remote (best effort; note if the cursor stays visible).
- [ ] Latency: record a 240 fps phone video of cursor-to-pointer; target p95 < 10 ms.

- [ ] **Step 4: Update `README.md` testing section, commit**

Add under Quick Start: `scripts/test_server.sh` (server unit tests), `cd mac && swift test` (Mac unit tests), `DESKBRIDGE_DEVICE=1 swift test --filter DeviceSmokeTests` (with a device), and `scripts/run_on_device.sh com.deskbridge.server.PointerSpike` (injection diagnostic).

```bash
git add mac/ README.md
git commit -m "test: device smoke tests (handshake, token rejection) and acceptance checklist"
```

---

## Plan Self-Review

- **Spec coverage:** server via `app_process` (T1–T3), injection (T2, gate), relative mouse + edge transition both ways (T3 `PointerState`, T7, T9), keyboard with full map and Cmd→Ctrl (T7, T9), right-click = Back with toggle (T9, T10), scroll (T2, T3, T8, T9), secure transport (T3, T5), fail-safes (T7, T9), packaging and permissions (T10), device verification (T11).
- **Out of MVP, stated in ARCHITECTURE §7:** clipboard, IME/Vietnamese text, top/bottom edges, mid-visit rotation, wireless ADB, multiple devices.
- **Biggest open risk:** Task 2 gate (does Android draw a pointer for injected events?). All later Mac tasks are independent of the answer; only `InputInjector` (and possibly `KeyMapper` for UHID) change.
- **Type consistency:** packet types, sizes, `0=DOWN/1=UP`, edge codes and token length match between `PacketType.java` / `ProtocolDecoder.java` and `Packets.swift`.
