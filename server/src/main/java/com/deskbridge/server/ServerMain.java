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
