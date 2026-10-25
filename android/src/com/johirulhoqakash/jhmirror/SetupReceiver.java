package com.johirulhoqakash.jhmirror;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.util.UUID;

public final class SetupReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        SharedPreferences prefs = context.getSharedPreferences("bridge", 0);
        if ("com.johirulhoqakash.jhmirror.DEVICE_STATUS".equals(intent.getAction())) {
            try { setResultCode(0); setResultData(new JSONObject().put("device", DeviceStatus.info(context)).put("features", DeviceStatus.rows(context)).toString()); }
            catch (Exception unavailable) { setResultCode(1); }
        } else if ("com.johirulhoqakash.jhmirror.TOUCH_GUARD".equals(intent.getAction())) {
            // This receiver is DUMP-protected: commands come from the authorized ADB shell.
            String action = intent.getStringExtra("operation");
            String result = "unavailable";
            try {
                if ("state".equals(action)) result = TouchGuardService.blackRequested(context) ? "black" : "screen-on";
                else if ("screen-on".equals(action) && TouchGuardService.instance == null) {
                    TouchGuardService.rememberBlack(context, false); result = "screen-on";
                }
                else if ("status".equals(action)) result = TouchGuardService.status(context);
                else if ("repair".equals(action)) {
                    final PendingResult pending = goAsync();
                    try { TouchGuardService.reconnect(context.getApplicationContext(), value -> {
                        pending.setResultCode(0); pending.setResultData(value); pending.finish();
                    }); } catch (RuntimeException error) { pending.setResultData("permission-denied"); pending.finish(); }
                    return;
                }
                else if ("prepare".equals(action)) result = android.os.Build.VERSION.SDK_INT < 34 ? "unsupported"
                    : TouchGuardService.enable(context) ? TouchGuardService.status(context) : "permission-denied";
                else if (TouchGuardService.instance != null) result = TouchGuardService.instance.command(action, intent.getStringExtra("lease"));
            } catch (SecurityException denied) { result = "permission-denied"; }
              catch (RuntimeException unavailable) { result = "service-disconnected"; }
            setResultCode(0); setResultData(result);
        } else if ("com.johirulhoqakash.jhmirror.SCAN_FILE".equals(intent.getAction())) {
            // DUMP-protected and restricted to shared storage; never scan app-private paths.
            try {
                java.io.File root = android.os.Environment.getExternalStorageDirectory().getCanonicalFile();
                java.io.File file = new java.io.File(intent.getStringExtra("path")).getCanonicalFile();
                String path = file.getPath(), base = root.getPath() + "/";
                if (!file.isFile() || !path.startsWith(base) || path.startsWith(base + "Android/data/") || path.startsWith(base + "Android/obb/")) { setResultCode(1); return; }
                android.media.MediaScannerConnection.scanFile(context, new String[]{path}, null, null);
                setResultCode(0);
            } catch (Exception unavailable) { setResultCode(1); }
        } else if ("com.johirulhoqakash.jhmirror.CONFIGURE".equals(intent.getAction())) {
            String token = intent.getStringExtra("token");
            if (token == null || !token.matches("[0-9a-f]{64}")) { setResultCode(1); return; }
            prefs.edit().putString("token", token).commit();
            boolean listening = BridgeState.start(context);
            WifiBridge.start(context); ConnectionService.ensure(context);
            // Result 0 is reported only when the Mac can actually reach the bridge.
            setResultCode(listening ? 0 : 2);
        } else if ("com.johirulhoqakash.jhmirror.TEST".equals(intent.getAction())) {
            MainActivity.postTest(context); setResultCode(0);
        } else if ("com.johirulhoqakash.jhmirror.TEST_BRIDGE".equals(intent.getAction())) {
            // An ADB-only transport test; never posts a phone notification.
            String source = intent.getStringExtra("sourcePackage");
            if (source == null) source = context.getPackageName();
            if (!source.matches("[a-zA-Z0-9_.]{3,200}")) { setResultCode(1); return; }
            try {
                String label = context.getPackageManager().getApplicationLabel(
                    context.getPackageManager().getApplicationInfo(source, 0)).toString();
                JSONObject event = new JSONObject();
                event.put("type", "posted"); event.put("key", "bridge-test-" + UUID.randomUUID());
                event.put("package", source); event.put("app", label);
                event.put("title", "JH Mirror test");
                event.put("body", "Original phone app icon test. No message was sent.");
                event.put("time", System.currentTimeMillis()); event.put("icon", AppIcons.get(context, source));
                BridgeState.add(event); setResultCode(0);
            } catch (Exception ignored) { setResultCode(1); }
        }
    }
}
