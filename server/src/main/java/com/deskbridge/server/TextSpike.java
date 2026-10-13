package com.deskbridge.server;

/**
 * Diagnostic for typing text and the clipboard. Run via scripts/run_on_device.sh with a text field focused.
 * Modes: "text STRING" types it like a Mac input method commit (ASCII as keys, accents pasted); "set STRING" / "get"
 * write / read the clipboard. STRING must be one word (the shell splits on spaces).
 */
public final class TextSpike {
    public static void main(String[] args) throws Exception {
        String mode = args.length > 0 ? args[0] : "";
        String text = args.length > 1 ? args[1] : "";
        switch (mode) {
            case "text":
                new InputInjector().text(text);
                System.out.println("text " + text);
                break;
            case "set":
                new ClipboardAccess().set(text);
                System.out.println("set " + text);
                break;
            case "get":
                System.out.println("clipboard: " + new ClipboardAccess().get());
                break;
            default:
                System.out.println("usage: text|paste|set STRING, get");
        }
    }
}
