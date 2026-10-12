package com.deskbridge.server;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.PorterDuff;
import android.view.Surface;
import android.view.SurfaceControl;

/**
 * Mouse pointer drawn by the server itself: injected events do not move Android's system pointer,
 * but a shell-owned SurfaceControl layer can be drawn above everything (verified on Android 13).
 */
final class CursorOverlay implements AutoCloseable {
    private static final float BASE_WIDTH = 1080f;
    private static final float TIP = 2f; // arrow tip offset inside the 48x72 sprite (hotspot)

    private final SurfaceControl layer;
    private final SurfaceControl.Transaction transaction = new SurfaceControl.Transaction();
    private final float scale;

    CursorOverlay(int displayWidth) {
        scale = Math.max(1f, displayWidth / BASE_WIDTH);
        layer = new SurfaceControl.Builder()
                .setName("DeskBridgeCursor")
                .setBufferSize(Math.round(48 * scale), Math.round(72 * scale))
                .setFormat(PixelFormat.TRANSLUCENT)
                .build();
        draw();
        transaction.setLayer(layer, Integer.MAX_VALUE - 1).setVisibility(layer, false).apply();
    }

    private void draw() {
        Surface surface = new Surface(layer);
        Canvas canvas = surface.lockCanvas(null);
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
        canvas.scale(scale, scale);

        Path arrow = new Path();
        arrow.moveTo(TIP, TIP);
        arrow.lineTo(TIP, 54);
        arrow.lineTo(16, 42);
        arrow.lineTo(26, 66);
        arrow.lineTo(34, 62);
        arrow.lineTo(24, 40);
        arrow.lineTo(42, 40);
        arrow.close();

        Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        fill.setColor(Color.WHITE);
        canvas.drawPath(arrow, fill);
        Paint outline = new Paint(Paint.ANTI_ALIAS_FLAG);
        outline.setStyle(Paint.Style.STROKE);
        outline.setStrokeWidth(3);
        outline.setColor(Color.BLACK);
        canvas.drawPath(arrow, outline);

        surface.unlockCanvasAndPost(canvas);
        surface.release();
    }

    void show(float x, float y) {
        transaction.setPosition(layer, x - TIP * scale, y - TIP * scale).setVisibility(layer, true).apply();
    }

    void moveTo(float x, float y) {
        transaction.setPosition(layer, x - TIP * scale, y - TIP * scale).apply();
    }

    void hide() {
        transaction.setVisibility(layer, false).apply();
    }

    @Override
    public void close() {
        hide();
        layer.release();
        transaction.close();
    }
}
