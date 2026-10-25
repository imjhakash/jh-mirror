package com.johirulhoqakash.jhmirror;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.provider.Settings;

/**
 * Switches Android's Wireless debugging on for the paired Mac, for example after a phone restart.
 * Requires WRITE_SECURE_SETTINGS, which only an authorized ADB connection can grant. Android keeps
 * its usual protections: only devices already paired with this phone can connect, and an untrusted
 * Wi-Fi network still asks for confirmation on the phone.
 */
final class AdbWifi {
    private static final String SETTING = "adb_wifi_enabled";

    static boolean canEnable(Context context) {
        return context != null && context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean enabled(Context context) {
        return context != null && Settings.Global.getInt(context.getContentResolver(), SETTING, 0) == 1;
    }

    static boolean enable(Context context) {
        if (!canEnable(context)) return false;
        if (enabled(context)) return true;
        try {
            return Settings.Global.putInt(context.getContentResolver(), SETTING, 1);
        } catch (SecurityException e) {
            return false;
        }
    }
}
