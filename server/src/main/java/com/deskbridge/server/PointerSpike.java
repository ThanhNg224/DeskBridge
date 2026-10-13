package com.deskbridge.server;

/**
 * Diagnostic. Run via scripts/run_on_device.sh and watch the phone: pointer, click, scroll, Back.
 * Modes: (none) full sweep; "click X Y" a single click; "hold" parks the pointer for 15 s.
 */
public final class PointerSpike {
    public static void main(String[] args) throws Exception {
        InputInjector injector = new InputInjector();
        DisplayHelper.Size size = DisplayHelper.query();
        System.out.println("display " + size.width + "x" + size.height + " rotation " + size.rotation);
        float cx = size.width / 2f;
        float cy = size.height / 2f;

        try (CursorOverlay overlay = new CursorOverlay(size.width)) {
            if (args.length == 3 && args[0].equals("click")) {
                float x = Float.parseFloat(args[1]);
                float y = Float.parseFloat(args[2]);
                overlay.show(x, y);
                Thread.sleep(1500); // let the overlay layer register with the input dispatcher first
                injector.hover(x, y);
                Thread.sleep(100);
                injector.button(1, true, x, y);
                Thread.sleep(60);
                injector.button(1, false, x, y);
                System.out.println("clicked " + x + "," + y);
                return;
            }

            if (args.length > 0 && args[0].equals("hold")) {
                overlay.show(cx, cy);
                injector.hover(cx, cy);
                System.out.println("holding pointer at the center for 15 s");
                Thread.sleep(15_000);
                injector.hoverExit(cx, cy);
                return;
            }

            System.out.println("1/4 hover sweep: the arrow should move diagonally");
            overlay.show(0, 0);
            for (int i = 0; i <= 120; i++) {
                float x = (size.width - 1) * i / 120f;
                float y = (size.height - 1) * i / 120f;
                overlay.moveTo(x, y);
                injector.hover(x, y);
                Thread.sleep(16);
            }

            System.out.println("2/4 click at the center");
            overlay.moveTo(cx, cy);
            injector.hover(cx, cy);
            Thread.sleep(300);
            injector.button(1, true, cx, cy);
            Thread.sleep(80);
            injector.button(1, false, cx, cy);
            Thread.sleep(500);

            System.out.println("3/4 scroll down by 3 lines");
            injector.scroll(cx, cy, 0f, -3f);
            Thread.sleep(500);

            System.out.println("4/4 Back key");
            injector.key(4, 0, 0);
            injector.key(4, 1, 0);
            Thread.sleep(300);

            injector.hoverExit(cx, cy);
            System.out.println("done");
        }
    }
}
