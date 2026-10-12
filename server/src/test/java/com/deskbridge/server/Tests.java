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
