package com.johirulhoqakash.jhmirror;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;

/** Consumes physical touchscreen/stylus events only while the paired Mac holds a short lease.
 * ADB-injected events bypass Android's physical input filter. No window content is requested.
 */
public final class TouchGuardService extends AccessibilityService {
    static TouchGuardService instance;
    private final TouchGuardLease lease = new TouchGuardLease();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable expiry = () -> release("lease expired");
    private boolean registered;
    private boolean filtering;
    private static boolean reconnecting;
    static boolean blackRequested(Context context) {
        return context.getSharedPreferences("bridge", 0).getBoolean("phoneBlackRequested", false);
    }
    static void rememberBlack(Context context, boolean black) {
        context.getSharedPreferences("bridge", 0).edit().putBoolean("phoneBlackRequested", black).apply();
    }
    private final BroadcastReceiver power = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            PowerManager manager = (PowerManager) getSystemService(POWER_SERVICE);
            // Some OEMs announce a physical panel change while Android remains interactive.
            // A real power-button sleep is noninteractive; a real wake also releases the guard.
            if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) {
                rememberBlack(context, false);
                release("phone display turned on");
            } else if (!manager.isInteractive()) {
                release("phone power state changed");
            }
        }
    };

    static boolean enable(Context context) {
        if (Build.VERSION.SDK_INT < 34) return false;
        String current = Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (!TouchGuardConfig.contains(current) && !Settings.Secure.putString(context.getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, TouchGuardConfig.with(current))) return false;
        return Settings.Secure.getInt(context.getContentResolver(), Settings.Secure.ACCESSIBILITY_ENABLED, 0) == 1
                || Settings.Secure.putInt(context.getContentResolver(), Settings.Secure.ACCESSIBILITY_ENABLED, 1);
    }

    static String status(Context context) {
        if (Build.VERSION.SDK_INT < 34) return "unsupported";
        if (instance != null) return "ready";
        String current = Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        return TouchGuardConfig.contains(current) ? "service-disconnected" : "service-disabled";
    }

    static void reconnect(Context context, java.util.function.Consumer<String> complete) {
        if (instance != null) { complete.accept("ready"); return; }
        if (reconnecting) { complete.accept("preparing"); return; }
        String current = Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (!TouchGuardConfig.contains(current)) { complete.accept("service-disabled"); return; }
        // Android does not rebind a crashed service when the enabled list stays
        // unchanged. Remove only our existing entry, then re-read before adding it.
        if (!Settings.Secure.putString(context.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                TouchGuardConfig.without(current))) { complete.accept("permission-denied"); return; }
        reconnecting = true;
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            String result = "permission-denied";
            try { result = enable(context) ? "preparing" : "permission-denied"; }
            catch (RuntimeException error) { Log.w("JHTouchGuard", "Service recovery failed", error); }
            finally { reconnecting = false; complete.accept(result); }
        }, 500);
    }

    @Override protected void onServiceConnected() {
        release("service connected"); // Rebinding, upgrading and restarting never restore a previous lease.
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_OFF); filter.addAction(Intent.ACTION_SCREEN_ON);
        if (!registered) {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(power, filter, Context.RECEIVER_NOT_EXPORTED);
            else registerReceiver(power, filter);
            registered = true;
        }
        instance = this;
    }

    String command(String action, String token) {
        if (Build.VERSION.SDK_INT < 34) return "unsupported";
        if ("screen-on".equals(action)) {
            rememberBlack(this, false); release(); return "screen-on";
        }
        if ("stop".equals(action)) {
            if (lease.matches(token)) release();
            return "released";
        }
        AccessibilityManager manager = (AccessibilityManager) getSystemService(ACCESSIBILITY_SERVICE);
        // Touch exploration takes priority over generic motion filtering; do not claim protection.
        if (manager.isTouchExplorationEnabled()) { release(); return "touch-exploration"; }
        long now = SystemClock.elapsedRealtime();
        boolean ok = "begin".equals(action) ? lease.begin(token, now) : "renew".equals(action) && lease.renew(token, now);
        if (!ok) { if (!lease.active(now)) release(); return blackRequested(this) ? "released" : "screen-on"; }
        try {
            AccessibilityServiceInfo info = getServiceInfo();
            info.setMotionEventSources(InputDevice.SOURCE_TOUCHSCREEN | InputDevice.SOURCE_STYLUS);
            setServiceInfo(info);
            filtering = true;
            rememberBlack(this, true);
            handler.removeCallbacks(expiry);
            handler.postDelayed(expiry, TouchGuardLease.TIMEOUT_MS);
            return "guarded";
        } catch (RuntimeException error) { Log.w("JHTouchGuard", "Motion filter unavailable", error); release(); return "filter-unavailable"; }
    }

    private void release() { release("Mac request or unavailable filter"); }
    private void release(String reason) {
        if (filtering) Log.i("JHTouchGuard", "Touch restored: " + reason);
        filtering = false;
        lease.release(); handler.removeCallbacks(expiry);
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                AccessibilityServiceInfo info = getServiceInfo();
                if (info != null) { info.setMotionEventSources(0); setServiceInfo(info); }
            } catch (RuntimeException error) { Log.w("JHTouchGuard", "Releasing unavailable filter", error); disableSelf(); }
        }
    }
    @Override public void onMotionEvent(MotionEvent event) { /* Intentionally consume physical touches; never record them. */ }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
    @Override public void onInterrupt() { release(); }
    @Override public void onDestroy() {
        release(); instance = null;
        if (registered) unregisterReceiver(power);
        super.onDestroy();
    }
}
