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
        try (CursorOverlay overlay = new CursorOverlay(Math.min(size.width, size.height))) {
            Session session = new Session(injector, overlay, pointer, out, () -> {
                try {
                    DisplayHelper.Size now = DisplayHelper.query();
                    return new int[] {now.width, now.height};
                } catch (ReflectiveOperationException e) {
                    throw new IllegalStateException("display query failed", e);
                }
            });
            ProtocolDecoder decoder = new ProtocolDecoder(session);
            try {
                while (decoder.processNext(in)) {
                    // loop until EOF
                }
            } finally {
                session.streamEnded();
            }
        }
    }
}
