package com.deskbridge.server.protocol;

public final class PacketType {
    private PacketType() {}

    public static final int VERSION = 1;
    public static final int TOKEN_LENGTH = 32;
    /** Largest TEXT payload (UTF-8 bytes): one word or phrase committed by a Mac input method. */
    public static final int MAX_TEXT_BYTES = 4096;
    /** Largest clipboard text (UTF-8 bytes) either side sends. */
    public static final int MAX_CLIPBOARD_BYTES = 1 << 20;

    public static final byte HELLO          = 0x01;
    public static final byte HELLO_OK       = 0x02;
    public static final byte ENTER          = 0x04;
    public static final byte EXIT           = 0x05;
    public static final byte LEAVE          = 0x06;
    public static final byte MOUSE_MOVE_REL = 0x11;
    public static final byte MOUSE_BUTTON   = 0x12;
    public static final byte MOUSE_SCROLL   = 0x13;
    public static final byte KEY_EVENT      = 0x20;
    public static final byte TEXT           = 0x21;
    public static final byte CLIPBOARD      = 0x30;
    public static final byte PING           = (byte) 0xFE;
    public static final byte PONG           = (byte) 0xFF;
}
