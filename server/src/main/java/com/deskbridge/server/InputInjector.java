package com.deskbridge.server;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Injects mouse and keyboard events through the hidden InputManager. Failures are unchecked (fail fast). */
public final class InputInjector {
    private static final int MOUSE_DEVICE_ID = 0;
    private static final int KEYBOARD_DEVICE_ID = -1; // KeyCharacterMap.VIRTUAL_KEYBOARD
    private static final int INJECT_MODE_ASYNC = 0;

    private final Object inputManager;
    private final Method injectMethod;
    private final Method setActionButtonMethod; // @hide in the SDK stubs, so reflected like the rest
    private int buttonState;
    private long downTime;
    private long keyDownTime;

    public InputInjector() throws ReflectiveOperationException {
        Class<?> managerClass = Class.forName("android.hardware.input.InputManager");
        Method getInstance = managerClass.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        inputManager = getInstance.invoke(null);
        injectMethod = managerClass.getMethod("injectInputEvent", InputEvent.class, int.class);
        setActionButtonMethod = MotionEvent.class.getMethod("setActionButton", int.class);
    }

    /** Moves the pointer; a drag if a button is held, a hover otherwise. */
    public void hover(float x, float y) {
        motion(buttonState == 0 ? MotionEvent.ACTION_HOVER_MOVE : MotionEvent.ACTION_MOVE, x, y, 0, 0f, 0f);
    }

    public void hoverExit(float x, float y) {
        motion(MotionEvent.ACTION_HOVER_EXIT, x, y, 0, 0f, 0f);
    }

    /** button is an Android MotionEvent.BUTTON_* bit. */
    public void button(int button, boolean down, float x, float y) {
        if (down) {
            boolean first = buttonState == 0;
            buttonState |= button;
            if (first) {
                downTime = SystemClock.uptimeMillis();
                motion(MotionEvent.ACTION_DOWN, x, y, 0, 0f, 0f);
            }
            motion(MotionEvent.ACTION_BUTTON_PRESS, x, y, button, 0f, 0f);
        } else {
            buttonState &= ~button;
            motion(MotionEvent.ACTION_BUTTON_RELEASE, x, y, button, 0f, 0f);
            if (buttonState == 0) {
                motion(MotionEvent.ACTION_UP, x, y, 0, 0f, 0f);
            }
        }
    }

    /** Wheel lines, Android axis sign (positive vertical = up). */
    public void scroll(float x, float y, float h, float v) {
        motion(MotionEvent.ACTION_SCROLL, x, y, 0, h, v);
    }

    /** action: KeyEvent.ACTION_DOWN (0) / ACTION_UP (1). */
    public void key(int keyCode, int action, int metaState) {
        long now = SystemClock.uptimeMillis();
        if (action == KeyEvent.ACTION_DOWN) {
            keyDownTime = now;
        }
        inject(new KeyEvent(keyDownTime, now, action, keyCode, 0, metaState,
                KEYBOARD_DEVICE_ID, 0, 0, InputDevice.SOURCE_KEYBOARD));
    }

    /** Releases any held mouse buttons so nothing stays pressed after a session ends. */
    public void releaseAll(float x, float y) {
        for (int bit = 1; bit <= 0x10 && buttonState != 0; bit <<= 1) {
            if ((buttonState & bit) != 0) {
                button(bit, false, x, y);
            }
        }
    }

    private void motion(int action, float x, float y, int actionButton, float hScroll, float vScroll) {
        long now = SystemClock.uptimeMillis();

        MotionEvent.PointerProperties[] props = {new MotionEvent.PointerProperties()};
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;

        MotionEvent.PointerCoords[] coords = {new MotionEvent.PointerCoords()};
        coords[0].x = x;
        coords[0].y = y;
        coords[0].pressure = buttonState != 0 ? 1f : 0f;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll);

        MotionEvent event = MotionEvent.obtain(downTime, now, action, 1, props, coords,
                0, buttonState, 1f, 1f, MOUSE_DEVICE_ID, 0, InputDevice.SOURCE_MOUSE, 0);
        try {
            if (actionButton != 0) {
                setActionButtonMethod.invoke(event, actionButton);
            }
            inject(event);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("setActionButton failed: " + e, e);
        } finally {
            event.recycle();
        }
    }

    private void inject(InputEvent event) {
        try {
            injectMethod.invoke(inputManager, event, INJECT_MODE_ASYNC);
        } catch (InvocationTargetException e) {
            throw new IllegalStateException("Input injection failed: " + e.getCause(), e.getCause());
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("Input injection failed: " + e, e);
        }
    }
}
