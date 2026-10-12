package com.deskbridge.server;

/** Run on a device via scripts/run_on_device.sh. Watch the screen: pointer, click, scroll, Back. */
public final class PointerSpike {
    public static void main(String[] args) throws Exception {
        InputInjector injector = new InputInjector();
        DisplayHelper.Size size = DisplayHelper.query();
        System.out.println("display " + size.width + "x" + size.height + " rotation " + size.rotation);
        float cx = size.width / 2f;
        float cy = size.height / 2f;

        System.out.println("1/4 hover sweep: a mouse pointer should be visible and move diagonally");
        for (int i = 0; i <= 120; i++) {
            injector.hover((size.width - 1) * i / 120f, (size.height - 1) * i / 120f);
            Thread.sleep(16);
        }

        System.out.println("2/4 click at the center");
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
