package com.deskbridge.server;

/** Android-side pointer position for one "visit". Pure logic, no Android dependencies. */
public final class PointerState {
    public static final int EDGE_LEFT = 0;
    public static final int EDGE_RIGHT = 1;

    private int width;
    private int height;
    private int entryEdge;
    private boolean entered;
    private float x;
    private float y;

    /** `along` (0..1) is the position along the entry edge. */
    public void enter(int width, int height, int edge, float along) {
        this.width = width;
        this.height = height;
        this.entryEdge = edge;
        this.entered = true;
        this.x = edge == EDGE_LEFT ? 0 : width - 1;
        this.y = clamp(along * (height - 1), 0, height - 1);
    }

    public void leave() {
        entered = false;
    }

    public boolean isEntered() { return entered; }
    public float x() { return x; }
    public float y() { return y; }

    /** Normalized position along the vertical axis, for EXIT. */
    public float along() {
        return height > 1 ? y / (height - 1) : 0f;
    }

    /**
     * Applies a relative move. Returns true when the pointer pushed back through the entry edge;
     * the visit is then over (isEntered() == false) and the position stays on that edge.
     */
    public boolean moveBy(float dx, float dy) {
        float nx = x + dx;
        boolean exit = (entryEdge == EDGE_LEFT && nx < 0) || (entryEdge == EDGE_RIGHT && nx > width - 1);
        y = clamp(y + dy, 0, height - 1);
        if (exit) {
            entered = false;
            return true;
        }
        x = clamp(nx, 0, width - 1);
        return false;
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
