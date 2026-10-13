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
        void onClipboard(String text) throws IOException;
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
            case PacketType.CLIPBOARD: {
                int length = in.readInt();
                if (length < 0 || length > PacketType.MAX_CLIPBOARD_BYTES) {
                    throw new IOException("Bad clipboard length " + length);
                }
                byte[] bytes = new byte[length];
                in.readFully(bytes);
                listener.onClipboard(new String(bytes, StandardCharsets.UTF_8));
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
