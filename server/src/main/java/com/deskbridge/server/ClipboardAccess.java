package com.deskbridge.server;

import android.content.ClipData;
import android.os.IBinder;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * The phone's clipboard through the hidden IClipboard service, as the shell user. The method signatures differ
 * between Android versions (attribution tag in 12, device id in 14), so each argument is filled by its type:
 * ClipData, the calling package (the first String), then null / 0 for the rest (attribution tag, user, device).
 */
public final class ClipboardAccess implements Session.Clipboard {
    private static final String PACKAGE = "com.android.shell";

    private final Object service;
    private final Method setPrimaryClip;
    private final Method getPrimaryClip;
    private final Method clearPrimaryClip;

    public ClipboardAccess() throws ReflectiveOperationException {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class)
                .invoke(null, "clipboard");
        if (binder == null) {
            throw new IllegalStateException("clipboard service not found");
        }
        service = Class.forName("android.content.IClipboard$Stub").getMethod("asInterface", IBinder.class)
                .invoke(null, binder);
        setPrimaryClip = find("setPrimaryClip");
        getPrimaryClip = find("getPrimaryClip");
        clearPrimaryClip = find("clearPrimaryClip");
    }

    @Override
    public void set(String text) {
        call(setPrimaryClip, ClipData.newPlainText("DeskBridge", text));
    }

    public void clear() {
        call(clearPrimaryClip, null);
    }

    @Override
    public String get() {
        ClipData clip = (ClipData) call(getPrimaryClip, null);
        if (clip == null || clip.getItemCount() == 0) {
            return null;
        }
        CharSequence text = clip.getItemAt(0).getText();
        return text == null ? null : text.toString();
    }

    private Method find(String name) {
        Method best = null;
        for (Method method : service.getClass().getMethods()) {
            if (method.getName().equals(name)
                    && (best == null || method.getParameterTypes().length > best.getParameterTypes().length)) {
                best = method;
            }
        }
        if (best == null) {
            throw new IllegalStateException("IClipboard." + name + " not found");
        }
        return best;
    }

    private Object call(Method method, ClipData clip) {
        Class<?>[] types = method.getParameterTypes();
        Object[] args = new Object[types.length];
        boolean packageSet = false;
        for (int i = 0; i < types.length; i++) {
            if (types[i] == ClipData.class) {
                args[i] = clip;
            } else if (types[i] == String.class) {
                args[i] = packageSet ? null : PACKAGE;
                packageSet = true;
            } else if (types[i] == int.class) {
                args[i] = 0;
            } else {
                throw new IllegalStateException("unexpected parameter " + types[i] + " in " + method);
            }
        }
        try {
            return method.invoke(service, args);
        } catch (InvocationTargetException e) {
            throw new IllegalStateException("clipboard call failed: " + e.getCause(), e.getCause());
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("clipboard call failed: " + e, e);
        }
    }
}
