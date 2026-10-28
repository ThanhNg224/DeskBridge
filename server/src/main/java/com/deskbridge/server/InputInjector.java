package com.deskbridge.server;

import android.os.Build;
import android.os.IBinder;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/** Injects mouse and keyboard events through the hidden InputManager. Failures are unchecked (fail fast). */
public final class InputInjector implements Session.Input {
    private static final int MOUSE_DEVICE_ID = 0;
    private static final int KEYBOARD_DEVICE_ID = -1; // KeyCharacterMap.VIRTUAL_KEYBOARD
    private static final int INJECT_MODE_ASYNC = 0;
    private static final int KEYCODE_WAKEUP = 224;
    private static final int KEYCODE_SLEEP = 223;
    private static final long WAKE_CHECK_INTERVAL_MS = 300;
    private static final int KEYCODE_V = 50;
    private static final int KEYCODE_CTRL_LEFT = 113;
    private static final int META_CTRL = 0x1000 | 0x2000; // META_CTRL_ON | META_CTRL_LEFT_ON
    /** The pasted text is read by the app asynchronously: the old clip may only come back after this. */
    private static final long PASTE_SETTLE_MS = 200;

    private final Object inputManager;
    private final Method injectMethod;
    private final Method setActionButtonMethod; // @hide in the SDK stubs, so reflected like the rest
    private final Object powerManager; // IPowerManager: injected mouse events do not wake a sleeping screen
    private final Method isInteractiveMethod;
    private final ClipboardAccess clipboard; // text with accents is pasted: key events cannot carry it
    private final KeyCharacterMap keyCharacterMap = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
    private long lastWakeCheck;
    private int buttonState;
    private long downTime;
    private final Map<Integer, Long> pressedKeys = new LinkedHashMap<>();

    public InputInjector() throws ReflectiveOperationException {
        // Android 14 moved injection to InputManagerGlobal; InputManager.getInstance() throws NPE there.
        Class<?> managerClass = Class.forName(Build.VERSION.SDK_INT >= 34
                ? "android.hardware.input.InputManagerGlobal"
                : "android.hardware.input.InputManager");
        Method getInstance = managerClass.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        inputManager = getInstance.invoke(null);
        injectMethod = managerClass.getMethod("injectInputEvent", InputEvent.class, int.class);
        setActionButtonMethod = MotionEvent.class.getMethod("setActionButton", int.class);

        Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class)
                .invoke(null, "power");
        powerManager = Class.forName("android.os.IPowerManager$Stub").getMethod("asInterface", IBinder.class)
                .invoke(null, binder);
        isInteractiveMethod = Class.forName("android.os.IPowerManager").getMethod("isInteractive");
        clipboard = new ClipboardAccess();
    }

    /** Moves the pointer; a drag if a button is held, a hover otherwise. */
    @Override
    public void hover(float x, float y) {
        wakeIfAsleep();
        motion(buttonState == 0 ? MotionEvent.ACTION_HOVER_MOVE : MotionEvent.ACTION_MOVE, x, y, 0, 0f, 0f);
    }

    @Override
    public void hoverExit(float x, float y) {
        motion(MotionEvent.ACTION_HOVER_EXIT, x, y, 0, 0f, 0f);
    }

    /** button is an Android MotionEvent.BUTTON_* bit. */
    @Override
    public void button(int button, boolean down, float x, float y) {
        if (down) {
            wakeIfAsleep();
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
    @Override
    public void scroll(float x, float y, float h, float v) {
        wakeIfAsleep();
        motion(MotionEvent.ACTION_SCROLL, x, y, 0, h, v);
    }

    /** action: KeyEvent.ACTION_DOWN (0) / ACTION_UP (1). */
    @Override
    public void key(int keyCode, int action, int metaState) {
        long now = SystemClock.uptimeMillis();
        long keyDownTime;
        if (action == KeyEvent.ACTION_DOWN) {
            if (keyCode != KEYCODE_SLEEP) {
                wakeIfAsleep();
            }
            keyDownTime = pressedKeys.getOrDefault(keyCode, now);
            pressedKeys.put(keyCode, keyDownTime);
        } else {
            Long previousDown = pressedKeys.remove(keyCode);
            keyDownTime = previousDown == null ? now : previousDown;
        }
        inject(new KeyEvent(keyDownTime, now, action, keyCode, 0, metaState,
                KEYBOARD_DEVICE_ID, 0, 0, InputDevice.SOURCE_KEYBOARD));
    }

    /**
     * Types text that a Mac input method already composed (Vietnamese Telex, ...). Plain ASCII goes in as key presses.
     * Anything else (accents) cannot be a key press, so it is pasted: the clipboard is set, Ctrl+V pressed and the
     * previous clip put back (a non-text clip is lost: it cannot be restored).
     */
    @Override
    public void text(String characters) {
        wakeIfAsleep();
        KeyEvent[] events = keyCharacterMap.getEvents(characters.toCharArray());
        if (events != null) {
            long now = SystemClock.uptimeMillis();
            for (KeyEvent event : events) {
                inject(new KeyEvent(now, now, event.getAction(), event.getKeyCode(), 0, event.getMetaState(),
                        KEYBOARD_DEVICE_ID, 0, 0, InputDevice.SOURCE_KEYBOARD));
            }
            return;
        }
        String previous = clipboard.get();
        clipboard.set(characters);
        key(KEYCODE_CTRL_LEFT, KeyEvent.ACTION_DOWN, META_CTRL);
        key(KEYCODE_V, KeyEvent.ACTION_DOWN, META_CTRL);
        key(KEYCODE_V, KeyEvent.ACTION_UP, META_CTRL);
        key(KEYCODE_CTRL_LEFT, KeyEvent.ACTION_UP, 0);
        try {
            Thread.sleep(PASTE_SETTLE_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        if (previous != null) {
            clipboard.set(previous);
        } else {
            clipboard.clear();
        }
    }

    /** Releases any held mouse buttons and keys so nothing stays pressed after a session ends. */
    @Override
    public void releaseAll(float x, float y) {
        for (Integer keyCode : new ArrayList<>(pressedKeys.keySet())) {
            key(keyCode, KeyEvent.ACTION_UP, 0);
        }
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

    /**
     * A real mouse wakes a sleeping phone, injected events do not: send KEYCODE_WAKEUP when the screen is off.
     * Checked at most every WAKE_CHECK_INTERVAL_MS (a binder call). Not done on releases, so leaving never wakes it.
     */
    private void wakeIfAsleep() {
        long now = SystemClock.uptimeMillis();
        if (now - lastWakeCheck < WAKE_CHECK_INTERVAL_MS) {
            return;
        }
        lastWakeCheck = now;
        try {
            if ((Boolean) isInteractiveMethod.invoke(powerManager)) {
                return;
            }
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("isInteractive failed: " + e, e);
        }
        for (int action : new int[] {KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP}) {
            inject(new KeyEvent(now, now, action, KEYCODE_WAKEUP, 0, 0,
                    KEYBOARD_DEVICE_ID, 0, 0, InputDevice.SOURCE_KEYBOARD));
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
