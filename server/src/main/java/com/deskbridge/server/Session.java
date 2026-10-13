package com.deskbridge.server;

import com.deskbridge.server.protocol.PacketType;
import com.deskbridge.server.protocol.ProtocolDecoder;

import java.io.DataOutputStream;
import java.io.IOException;
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
        /** Releases held mouse buttons and keys. */
        void releaseAll(float x, float y);
    }

    interface Cursor {
        void show(float x, float y);
        void moveTo(float x, float y);
        void hide();
    }

    private final Input input;
    private final Cursor cursor;
    private final PointerState pointer;
    private final DataOutputStream out;
    private final Supplier<int[]> displaySize; // {width, height}, re-read on every ENTER (rotation may change)

    Session(Input input, Cursor cursor, PointerState pointer, DataOutputStream out, Supplier<int[]> displaySize) {
        this.input = input;
        this.cursor = cursor;
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
        cursor.show(pointer.x(), pointer.y());
        input.hover(pointer.x(), pointer.y());
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

    @Override
    public void onPing() throws IOException {
        out.writeByte(PacketType.PONG);
        out.flush();
    }

    private void endVisit() {
        input.releaseAll(pointer.x(), pointer.y());
        input.hoverExit(pointer.x(), pointer.y());
        cursor.hide();
        pointer.leave();
    }
}
