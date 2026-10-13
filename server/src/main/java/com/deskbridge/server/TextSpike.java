package com.deskbridge.server;

import android.view.KeyEvent;

/**
 * Diagnostic for typing text and the clipboard. Run via scripts/run_on_device.sh with a text field focused.
 * Modes: "text STRING" injects the characters as one ACTION_MULTIPLE event; "paste STRING" sets the clipboard and
 * presses Ctrl+V; "set STRING" / "get" write / read the clipboard.
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
            case "paste": {
                new ClipboardAccess().set(text);
                InputInjector injector = new InputInjector();
                injector.key(KeyEvent.KEYCODE_PASTE, KeyEvent.ACTION_DOWN, 0);
                injector.key(KeyEvent.KEYCODE_PASTE, KeyEvent.ACTION_UP, 0);
                System.out.println("pasted " + text);
                break;
            }
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
