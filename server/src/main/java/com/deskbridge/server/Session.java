package com.deskbridge.server;

import com.deskbridge.server.protocol.PacketType;
import com.deskbridge.server.protocol.ProtocolDecoder;

import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.function.Supplier;

/**
 * Reacts to decoded host packets. Runs on the single session thread, so writes to `out` need no locking.
 * No Android dependencies: input and cursor are small interfaces so tests can use fakes.
 */
final class Session implements ProtocolDecoder.Listener {
    interface Input {
        void hover(float x, float y);
        void hoverExit(float x, float y);
        void button(int button, boolean down, float x, float y);
        void scroll(float x, float y, float h, float v);
        void key(int keyCode, int action, int metaState);
        /** Types text that a Mac input method already composed (it cannot be sent as key presses). */
        void text(String characters);
        /** Releases held mouse buttons and keys. */
        void releaseAll(float x, float y);
    }

    interface Cursor {
        void show(float x, float y);
        void moveTo(float x, float y);
        void hide();
    }

    interface Clipboard {
        void set(String text);
        /** Text of the current clip; null when empty or not text. */
        String get();
    }

    private final Input input;
    private final Cursor cursor;
    private final Clipboard clipboard;
    private final PointerState pointer;
    private final DataOutputStream out;
    private final Supplier<int[]> displaySize; // {width, height}, re-read on every ENTER (rotation may change)
    private boolean clipboardShared; // the host sent CLIPBOARD before this visit: it wants the clipboard shared
    private String clipboardBaseline; // the phone's clip when the visit began; only a different one goes back

    Session(Input input, Cursor cursor, Clipboard clipboard, PointerState pointer, DataOutputStream out,
            Supplier<int[]> displaySize) {
        this.input = input;
        this.cursor = cursor;
        this.clipboard = clipboard;
        this.pointer = pointer;
        this.out = out;
        this.displaySize = displaySize;
    }

    /** Call when the host stream ends so nothing stays pressed. */
    void streamEnded() {
        input.releaseAll(pointer.x(), pointer.y());
    }

    @Override
    public void onEnter(int edge, float along) {
        int[] size = displaySize.get();
        pointer.enter(size[0], size[1], edge, along);
        if (clipboardShared) {
            clipboardBaseline = clipboard.get();
        }
        cursor.show(pointer.x(), pointer.y());
        input.hover(pointer.x(), pointer.y());
    }

    @Override
    public void onLeave() throws IOException {
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
            endVisit();
            out.writeByte(PacketType.EXIT);
            out.writeFloat(pointer.along());
            out.flush();
        } else {
            cursor.moveTo(pointer.x(), pointer.y());
            input.hover(pointer.x(), pointer.y());
        }
    }

    @Override
    public void onMouseButton(int button, int action) {
        if (pointer.isEntered()) {
            input.button(button, action == 0, pointer.x(), pointer.y());
        }
    }

    @Override
    public void onMouseScroll(float h, float v) {
        if (pointer.isEntered()) {
            input.scroll(pointer.x(), pointer.y(), h, v);
        }
    }

    @Override
    public void onKeyEvent(int keyCode, int action, int metaState) {
        if (pointer.isEntered()) {
            input.key(keyCode, action, metaState);
        }
    }

    /** Contents are never logged. */
    @Override
    public void onText(String text) {
        if (pointer.isEntered()) {
            input.text(text);
        }
    }

    /** Contents are never logged. An empty text only says "share the clipboard this visit". */
    @Override
    public void onClipboard(String text) {
        clipboardShared = true;
        if (!text.isEmpty()) {
            clipboard.set(text);
        }
    }

    @Override
    public void onPing() throws IOException {
        out.writeByte(PacketType.PONG);
        out.flush();
    }

    /** Sends the phone's clip to the Mac if it changed during the visit (texts over the limit stay on the phone). */
    private void sendClipboardIfChanged() throws IOException {
        if (!clipboardShared) {
            return;
        }
        clipboardShared = false;
        String text = clipboard.get();
        if (text == null || text.equals(clipboardBaseline)) {
            return;
        }
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > PacketType.MAX_CLIPBOARD_BYTES) {
            return;
        }
        out.writeByte(PacketType.CLIPBOARD);
        out.writeInt(bytes.length);
        out.write(bytes);
        out.flush();
    }

    private void endVisit() throws IOException {
        sendClipboardIfChanged();
        input.releaseAll(pointer.x(), pointer.y());
        input.hoverExit(pointer.x(), pointer.y());
        cursor.hide();
        pointer.leave();
    }
}
