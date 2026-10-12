package com.deskbridge.server;

/** Logical display size/rotation (what injected coordinates are relative to), via hidden APIs. */
final class DisplayHelper {
    static final class Size {
        final int width;
        final int height;
        final int rotation;

        Size(int width, int height, int rotation) {
            this.width = width;
            this.height = height;
            this.rotation = rotation;
        }
    }

    private DisplayHelper() {}

    static Size query() throws ReflectiveOperationException {
        Class<?> manager = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object instance = manager.getMethod("getInstance").invoke(null);
        Object info = manager.getMethod("getDisplayInfo", int.class).invoke(instance, 0);
        Class<?> infoClass = info.getClass();
        return new Size(
                infoClass.getField("logicalWidth").getInt(info),
                infoClass.getField("logicalHeight").getInt(info),
                infoClass.getField("rotation").getInt(info));
    }
}
