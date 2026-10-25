package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;

/** Read-only platform facts plus recent observations from the authenticated paired Mac. */
final class DeviceStatus {
    static final String[] IDS = {"mirror", "files", "gallery", "camera", "microphone", "audio", "screenOff", "notifications", "apps"};
    static final String[] TITLES = {"Screen mirroring", "File transfer", "Media library", "Phone camera for calls", "Phone microphone for calls", "Phone audio on Mac", "Screen off & touch protection", "Notifications", "App Library"};
    static JSONObject info(Context context) throws Exception {
        PackageManager pm = context.getPackageManager();
        return new JSONObject().put("model", Build.MANUFACTURER + " " + Build.MODEL)
            .put("android", Build.VERSION.RELEASE).put("sdk", Build.VERSION.SDK_INT)
            .put("hasCamera", pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY))
            .put("hasMicrophone", pm.hasSystemFeature(PackageManager.FEATURE_MICROPHONE))
            .put("notificationAccess", BridgeState.listenerConnected)
            .put("notificationEnabled", context.getSharedPreferences("bridge", 0).getBoolean("enabled", true))
            .put("touchGuard", TouchGuardService.instance != null);
    }
    static int minimum(int index) { return index == 3 ? 31 : index == 4 || index == 5 ? 30 : index == 6 ? 34 : 26; }
    static String androidMinimum(int index) { return index == 3 ? "12" : index == 4 || index == 5 ? "11" : index == 6 ? "14" : "8"; }
    static JSONObject row(int index, String state, String label, String reason, String next) throws Exception {
        return new JSONObject().put("id", IDS[index]).put("state", state).put("label", label).put("reason", reason).put("nextStep", next);
    }
    static JSONArray rows(Context context) {
        JSONArray rows = new JSONArray();
        try {
            JSONObject facts = info(context);
            boolean connected = ConnectionService.isClientActive();
            JSONArray report = new JSONArray(context.getSharedPreferences("bridge", 0).getString("macDeviceStatus", "[]"));
            long age = System.currentTimeMillis() - context.getSharedPreferences("bridge", 0).getLong("macDeviceStatusTime", 0);
            for (int i = 0; i < IDS.length; i++) {
                JSONObject value;
                if (Build.VERSION.SDK_INT < minimum(i)) {
                    value = row(i, "red", "Unsupported", "Android " + Build.VERSION.RELEASE + " is installed. This feature requires Android " + androidMinimum(i) + " or newer.",
                        i == 6 ? "Keep the phone display on while mirroring. Other features can still work." : "Use a supported phone or an official Android update, if available.");
                } else if (i == 3 && !facts.optBoolean("hasCamera") || i == 4 && !facts.optBoolean("hasMicrophone")) {
                    value = row(i, "red", "Unsupported", "Android reports that this device has no " + (i == 3 ? "camera." : "microphone."), "");
                } else if (!connected) {
                    value = row(i, "yellow", "Not connected", "No recent connection from the paired Mac.", "Open JH Mirror on the Mac. For Android 10 or earlier, use an authorized USB connection.");
                } else {
                    value = row(i, "yellow", "Ready · not checked", "The Android requirements are met. A successful operation has not been checked yet.", "Open Device Check on the Mac, or use this feature. Camera and microphone start only when requested.");
                    if (age >= 0 && age < 60000) for (int j = 0; j < report.length(); j++) {
                        JSONObject candidate = report.getJSONObject(j);
                        if (IDS[i].equals(candidate.optString("id"))) { value = candidate; break; }
                    }
                    if (i == 7 && (!facts.optBoolean("notificationAccess") || !facts.optBoolean("notificationEnabled")))
                        value = row(i, "yellow", facts.optBoolean("notificationAccess") ? "Paused" : "Needs permission", "Phone notifications are off or notification access is missing.", "Open Settings below to enable notification access and Send notifications to Mac.");
                }
                rows.put(value);
            }
        } catch (Exception ignored) { }
        return rows;
    }
    static boolean saveReport(Context context, byte[] data) {
        try {
            if (data.length > 20000) return false;
            JSONArray incoming = new JSONArray(new String(data, StandardCharsets.UTF_8));
            if (incoming.length() != IDS.length) return false;
            Set<String> seen = new HashSet<>(); JSONArray clean = new JSONArray();
            for (int i = 0; i < incoming.length(); i++) {
                JSONObject item = incoming.getJSONObject(i); String id = item.getString("id"), state = item.getString("state");
                int index = java.util.Arrays.asList(IDS).indexOf(id);
                if (index < 0 || !seen.add(id) || !(state.equals("red") || state.equals("yellow") || state.equals("green"))) return false;
                if (item.getString("label").length() > 80 || item.getString("reason").length() > 800 || item.getString("nextStep").length() > 400) return false;
                clean.put(row(index, state, item.getString("label"), item.getString("reason"), item.getString("nextStep")));
            }
            context.getSharedPreferences("bridge", 0).edit().putString("macDeviceStatus", clean.toString()).putLong("macDeviceStatusTime", System.currentTimeMillis()).apply();
            return true;
        } catch (Exception invalid) { return false; }
    }
}
