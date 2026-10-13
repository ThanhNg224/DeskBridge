package com.deskbridge.server;

import com.deskbridge.server.protocol.PacketType;
import com.deskbridge.server.protocol.ProtocolDecoder;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

public final class Tests {
    /** Runs every static no-arg method whose name starts with "test". */
    public static void main(String[] args) {
        int total = 0;
        int failed = 0;
        Method[] methods = Tests.class.getDeclaredMethods();
        Arrays.sort(methods, Comparator.comparing(Method::getName));
        for (Method m : methods) {
            if (!m.getName().startsWith("test") || m.getParameterCount() != 0 || !Modifier.isStatic(m.getModifiers())) {
                continue;
            }
            total++;
            try {
                m.setAccessible(true);
                m.invoke(null);
                System.out.println("PASS " + m.getName());
            } catch (InvocationTargetException e) {
                failed++;
                System.out.println("FAIL " + m.getName() + ": " + e.getCause());
            } catch (ReflectiveOperationException e) {
                failed++;
                System.out.println("FAIL " + m.getName() + ": " + e);
            }
        }
        System.out.println(failed == 0 ? "OK " + total + " tests" : failed + " FAILED");
        System.exit(failed == 0 && total > 0 ? 0 : 1);
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
        @Override public void onText(String text) { events.add("text " + text); }
        @Override public void onClipboard(String text) { events.add("clipboard " + text); }
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

    static void testDecodeEnterAndLeave() throws Exception {
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

    static void testDecodeMoveButtonScrollKey() throws Exception {
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

    static void testDecodeClipboardMultibyteText() throws Exception {
        byte[] text = "tiếng Việt".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.CLIPBOARD); o.writeInt(text.length); o.write(text);
            o.writeByte(PacketType.CLIPBOARD); o.writeInt(0);
        });
        Recorder r = new Recorder();
        ProtocolDecoder d = new ProtocolDecoder(r);
        DataInputStream in = stream(bytes);
        while (d.processNext(in)) { /* drain */ }
        eq("clipboard tiếng Việt", r.events.get(0));
        eq("clipboard ", r.events.get(1));
    }

    static void testDecodeText() throws Exception {
        byte[] text = "tiếng".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] bytes = build(o -> { o.writeByte(PacketType.TEXT); o.writeInt(text.length); o.write(text); });
        Recorder r = new Recorder();
        new ProtocolDecoder(r).processNext(stream(bytes));
        eq("text tiếng", r.events.get(0));
    }

    static void testTextTooLargeIsRejected() throws Exception {
        for (int length : new int[] {PacketType.MAX_TEXT_BYTES + 1, -1}) {
            byte[] bytes = build(o -> { o.writeByte(PacketType.TEXT); o.writeInt(length); });
            try {
                new ProtocolDecoder(new Recorder()).processNext(stream(bytes));
            } catch (IOException expected) {
                continue;
            }
            throw new AssertionError("expected IOException for length " + length);
        }
    }

    static void testClipboardTooLargeIsRejected() throws Exception {
        for (int length : new int[] {PacketType.MAX_CLIPBOARD_BYTES + 1, -1}) {
            byte[] bytes = build(o -> { o.writeByte(PacketType.CLIPBOARD); o.writeInt(length); });
            try {
                new ProtocolDecoder(new Recorder()).processNext(stream(bytes));
            } catch (IOException expected) {
                continue;
            }
            throw new AssertionError("expected IOException for length " + length);
        }
    }

    static void testDecodePing() throws Exception {
        Recorder r = new Recorder();
        new ProtocolDecoder(r).processNext(stream(new byte[]{PacketType.PING}));
        eq("ping", r.events.get(0));
    }

    static void testUnknownPacketThrows() throws Exception {
        try {
            new ProtocolDecoder(new Recorder()).processNext(stream(new byte[]{0x7E}));
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("expected IOException");
    }

    static void testEofReturnsFalse() throws Exception {
        check(!new ProtocolDecoder(new Recorder()).processNext(stream(new byte[0])), "EOF must return false");
    }

    static void testHelloAccepted() throws Exception {
        byte[] bytes = build(o -> {
            o.writeByte(PacketType.HELLO); o.writeByte(PacketType.VERSION);
            o.write(TOKEN.getBytes(StandardCharsets.US_ASCII));
        });
        eq(TOKEN, ProtocolDecoder.readHello(stream(bytes)));
    }

    static void testHelloRejectsBadVersion() throws Exception {
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

    static void testHelloRejectsWrongType() throws Exception {
        try {
            ProtocolDecoder.readHello(stream(new byte[]{PacketType.PING}));
        } catch (IOException expected) {
            return;
        }
        throw new AssertionError("expected IOException");
    }

    // ---- pointer ----

    static void testPointerEnterLeftPlacesAtEdge() {
        PointerState p = new PointerState();
        p.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(p.isEntered(), "entered");
        near(0f, p.x());
        near(1199.5f, p.y());
        p.enter(1080, 2400, PointerState.EDGE_RIGHT, 0f);
        near(1079f, p.x());
        near(0f, p.y());
    }

    static void testPointerClamps() {
        PointerState p = new PointerState();
        p.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(!p.moveBy(5000f, 99999f), "no exit moving inward");
        near(1079f, p.x());
        near(2399f, p.y());
        check(!p.moveBy(-10f, -99999f), "no exit while inside");
        near(1069f, p.x());
        near(0f, p.y());
    }

    static void testPointerExitsThroughEntryEdge() {
        PointerState left = new PointerState();
        left.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(!left.moveBy(-1f, 0f), "jitter toward the edge right after entering must not exit");
        check(left.isEntered(), "still entered");
        check(!left.moveBy(100f, 0f), "moving inward arms the exit");
        check(left.moveBy(-500f, 0f), "left entry exits on negative x once armed");
        check(!left.isEntered(), "visit over");

        PointerState right = new PointerState();
        right.enter(1080, 2400, PointerState.EDGE_RIGHT, 0.5f);
        check(!right.moveBy(5000f, 0f), "pushing out before arming does not exit");
        check(!right.moveBy(-100f, 0f), "moving inward arms the exit");
        check(right.moveBy(5000f, 0f), "right entry exits past width once armed");
    }

    static void testPointerExitNeedsArmDistance() {
        PointerState p = new PointerState();
        p.enter(1080, 2400, PointerState.EDGE_LEFT, 0.5f);
        check(!p.moveBy(PointerState.ARM_DISTANCE - 1f, 0f), "just short of the arm distance");
        check(!p.moveBy(-(PointerState.ARM_DISTANCE + 10f), 0f), "still not armed, so no exit");
        check(!p.moveBy(PointerState.ARM_DISTANCE, 0f), "reaching the arm distance arms it");
        check(p.moveBy(-1000f, 0f), "now it exits");
    }

    static void testPointerAlong() {
        PointerState p = new PointerState();
        p.enter(1080, 2401, PointerState.EDGE_LEFT, 0.25f);
        near(0.25f, p.along());
    }

    static void testPointerTopBottomEntryAndExit() {
        PointerState top = new PointerState();
        top.enter(1080, 2400, PointerState.EDGE_TOP, 0.5f);
        near(539.5f, top.x());
        near(0f, top.y());
        check(!top.moveBy(0f, 100f), "moving down is inside");
        near(100f, top.y());
        near(539.5f / 1079f, top.along());
        check(top.moveBy(0f, -500f), "pushing up exits (armed by the earlier 100 px)");
        check(!top.isEntered(), "visit over");

        PointerState bottom = new PointerState();
        bottom.enter(1080, 2400, PointerState.EDGE_BOTTOM, 1f);
        near(1079f, bottom.x());
        near(2399f, bottom.y());
        check(!bottom.moveBy(0f, -300f), "moving up is inside and arms the exit");
        check(bottom.moveBy(0f, 5000f), "pushing down exits");
    }

    static void testPointerRejectsUnknownEdge() {
        try {
            new PointerState().enter(1080, 2400, 9, 0.5f);
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError("expected IllegalArgumentException");
    }

    // ---- session ----

    private static final class Fake implements Session.Input, Session.Cursor, Session.Clipboard {
        final List<String> calls = new ArrayList<>();
        String clip; // the phone's clipboard
        @Override public void set(String text) { calls.add("clipSet"); clip = text; }
        @Override public String get() { calls.add("clipGet"); return clip; }
        @Override public void hover(float x, float y) { calls.add("hover " + x + " " + y); }
        @Override public void hoverExit(float x, float y) { calls.add("hoverExit"); }
        @Override public void button(int b, boolean down, float x, float y) { calls.add("button " + b + " " + down); }
        @Override public void scroll(float x, float y, float h, float v) { calls.add("scroll"); }
        @Override public void key(int k, int a, int m) { calls.add("key " + k + " " + a); }
        @Override public void text(String characters) { calls.add("text " + characters); }
        @Override public void releaseAll(float x, float y) { calls.add("releaseAll"); }
        @Override public void show(float x, float y) { calls.add("show " + x + " " + y); }
        @Override public void moveTo(float x, float y) { calls.add("moveTo"); }
        @Override public void hide() { calls.add("hide"); }
        void count(String name, int expected) {
            int n = 0;
            for (String c : calls) if (c.startsWith(name)) n++;
            eq(expected, n);
        }
    }

    private static final class Rig {
        final Fake fake = new Fake();
        final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        final Session session = new Session(fake, fake, fake, new PointerState(), new DataOutputStream(bytes),
                () -> new int[] {1080, 2400});
    }

    /** Enters on the left edge and moves inward so the exit is armed. */
    private static Rig enteredRig() throws Exception {
        Rig r = new Rig();
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f);
        r.session.onMouseMoveRel(100f, 0f);
        r.fake.calls.clear();
        return r;
    }

    static void testSessionEnterShowsCursorAtEntryEdge() {
        Rig r = new Rig();
        r.session.onEnter(PointerState.EDGE_RIGHT, 0f);
        eq("show 1079.0 0.0", r.fake.calls.get(0));
        eq("hover 1079.0 0.0", r.fake.calls.get(1));
    }

    static void testSessionExitWritesPacketAndTearsDown() throws Exception {
        Rig r = enteredRig();
        r.session.onMouseMoveRel(-500f, 0f);
        byte[] b = r.bytes.toByteArray();
        eq(5, b.length);
        eq((int) PacketType.EXIT, (int) b[0]);
        eq(0x05, b[0] & 0xFF);
        near(0.5f, new DataInputStream(new ByteArrayInputStream(b, 1, 4)).readFloat());
        r.fake.count("hide", 1);
        r.fake.count("releaseAll", 1);
    }

    static void testSessionIgnoresInputBeforeEnter() throws Exception {
        Rig r = new Rig();
        r.session.onText("x");
        r.session.onMouseMoveRel(5f, 5f);
        r.session.onMouseButton(1, 0);
        r.session.onMouseScroll(0f, 1f);
        r.session.onKeyEvent(29, 0, 0);
        check(r.fake.calls.isEmpty(), "got " + r.fake.calls);
    }

    static void testSessionIgnoresInputAfterVisitEnded() throws Exception {
        Rig r = enteredRig();
        r.session.onMouseMoveRel(-500f, 0f);
        r.fake.calls.clear();
        r.session.onMouseMoveRel(5f, 5f);
        r.session.onMouseButton(1, 0);
        r.session.onMouseScroll(0f, 1f);
        r.session.onKeyEvent(29, 0, 0);
        check(r.fake.calls.isEmpty(), "got " + r.fake.calls);
    }

    static void testSessionForwardsInputWhileEntered() throws Exception {
        Rig r = enteredRig();
        r.session.onMouseButton(1, 0);
        r.session.onKeyEvent(29, 0, 0);
        r.session.onMouseScroll(0f, 1f);
        r.session.onText("tiếng");
        eq("button 1 true", r.fake.calls.get(0));
        eq("key 29 0", r.fake.calls.get(1));
        eq("scroll", r.fake.calls.get(2));
        eq("text tiếng", r.fake.calls.get(3));
    }

    static void testSessionPingWritesPong() throws Exception {
        Rig r = new Rig();
        r.session.onPing();
        eq(1, r.bytes.size());
        eq((int) PacketType.PONG, (int) r.bytes.toByteArray()[0]);
        eq(0xFF, r.bytes.toByteArray()[0] & 0xFF);
    }

    static void testSessionLeaveEndsVisitWithoutExit() throws Exception {
        Rig r = enteredRig();
        r.session.onKeyEvent(29, 0, 0);
        r.fake.calls.clear();
        r.session.onLeave();
        r.fake.count("releaseAll", 1);
        r.fake.count("hide", 1);
        eq(0, r.bytes.size());
        r.session.onMouseMoveRel(5f, 5f);
        r.fake.count("moveTo", 0);
    }

    static void testSessionStreamEndReleasesHeldInput() throws Exception {
        Rig r = enteredRig();
        r.session.onKeyEvent(29, 0, 0);
        r.fake.calls.clear();
        r.session.streamEnded();
        eq("releaseAll", r.fake.calls.get(0));
    }

    // ---- clipboard ----

    /** What the session wrote to `bytes` as a CLIPBOARD packet followed by anything else, as text. */
    private static String clipboardWritten(Rig r) throws IOException {
        DataInputStream in = stream(r.bytes.toByteArray());
        eq(0x30, in.readUnsignedByte());
        byte[] text = new byte[in.readInt()];
        in.readFully(text);
        return new String(text, java.nio.charset.StandardCharsets.UTF_8);
    }

    static void testClipboardFromMacIsSetOnThePhone() throws Exception {
        Rig r = new Rig();
        r.session.onClipboard("xin chào");
        eq("xin chào", r.fake.clip);
        r.fake.calls.clear();
        r.session.onClipboard(""); // "share, nothing new": must not clear the phone's clip
        eq("xin chào", r.fake.clip);
        r.fake.count("clipSet", 0);
    }

    static void testChangedPhoneClipGoesBackBeforeExit() throws Exception {
        Rig r = new Rig();
        r.session.onClipboard("from mac");
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f);
        r.session.onMouseMoveRel(100f, 0f);
        r.fake.clip = "từ điện thoại";
        r.session.onMouseMoveRel(-500f, 0f);
        eq("từ điện thoại", clipboardWritten(r));
        byte[] b = r.bytes.toByteArray();
        int exitAt = b.length - 5;
        eq(0x05, b[exitAt] & 0xFF); // CLIPBOARD comes first, EXIT last
    }

    static void testUnchangedPhoneClipIsNotSent() throws Exception {
        Rig r = new Rig();
        r.fake.clip = "old";
        r.session.onClipboard(""); // sharing on, nothing from the Mac
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f);
        r.session.onMouseMoveRel(100f, 0f);
        r.session.onMouseMoveRel(-500f, 0f);
        eq(5, r.bytes.size()); // EXIT only
    }

    static void testClipboardUntouchedWithoutOptIn() throws Exception {
        Rig r = new Rig();
        r.fake.clip = "secret";
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f);
        r.session.onMouseMoveRel(100f, 0f);
        r.fake.clip = "changed";
        r.session.onLeave();
        r.fake.count("clipGet", 0);
        eq(0, r.bytes.size());
    }

    static void testClipboardSharingEndsWithTheVisit() throws Exception {
        Rig r = new Rig();
        r.session.onClipboard("");
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f);
        r.session.onLeave();
        r.fake.calls.clear();
        r.session.onEnter(PointerState.EDGE_LEFT, 0.5f); // second visit, Mac did not opt in again
        r.session.onLeave();
        r.fake.count("clipGet", 0);
    }
}
