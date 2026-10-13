package com.deskbridge.server;

/** Android-side pointer position for one "visit". Pure logic, no Android dependencies. */
public final class PointerState {
    public static final int EDGE_LEFT = 0;
    public static final int EDGE_RIGHT = 1;
    public static final int EDGE_TOP = 2;
    public static final int EDGE_BOTTOM = 3;

    private int width;
    private int height;
    private int entryEdge;
    private boolean entered;
    private float x;
    private float y;

    /** `along` (0..1) is the position along the entry edge (vertical for left/right, horizontal for top/bottom). */
    public void enter(int width, int height, int edge, float along) {
        this.width = width;
        this.height = height;
        this.entryEdge = edge;
        this.entered = true;
        switch (edge) {
            case EDGE_LEFT:
                x = 0;
                y = clamp(along * (height - 1), 0, height - 1);
                break;
            case EDGE_RIGHT:
                x = width - 1;
                y = clamp(along * (height - 1), 0, height - 1);
                break;
            case EDGE_TOP:
                x = clamp(along * (width - 1), 0, width - 1);
                y = 0;
                break;
            case EDGE_BOTTOM:
                x = clamp(along * (width - 1), 0, width - 1);
                y = height - 1;
                break;
            default:
                throw new IllegalArgumentException("Unknown edge " + edge);
        }
    }

    public void leave() {
        entered = false;
    }

    public boolean isEntered() { return entered; }
    public float x() { return x; }
    public float y() { return y; }

    /** Normalized position along the entry edge, for EXIT. */
    public float along() {
        boolean vertical = entryEdge == EDGE_LEFT || entryEdge == EDGE_RIGHT;
        int length = vertical ? height : width;
        float position = vertical ? y : x;
        return length > 1 ? position / (length - 1) : 0f;
    }

    /**
     * Applies a relative move. Returns true when the pointer pushed back through the entry edge;
     * the visit is then over (isEntered() == false) and the position stays on that edge.
     */
    public boolean moveBy(float dx, float dy) {
        float nx = x + dx;
        float ny = y + dy;
        boolean exit = (entryEdge == EDGE_LEFT && nx < 0)
                || (entryEdge == EDGE_RIGHT && nx > width - 1)
                || (entryEdge == EDGE_TOP && ny < 0)
                || (entryEdge == EDGE_BOTTOM && ny > height - 1);
        x = clamp(nx, 0, width - 1);
        y = clamp(ny, 0, height - 1);
        if (exit) {
            entered = false;
        }
        return exit;
    }

    private static float clamp(float v, float min, float max) {
        return Math.max(min, Math.min(max, v));
    }
}
