package local.androidwireless.bridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import org.json.JSONObject;
import java.util.UUID;

public final class SetupReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        SharedPreferences prefs = context.getSharedPreferences("bridge", 0);
        if ("local.androidwireless.bridge.CONFIGURE".equals(intent.getAction())) {
            String token = intent.getStringExtra("token");
            if (token == null || !token.matches("[0-9a-f]{64}")) { setResultCode(1); return; }
            prefs.edit().putString("token", token).commit();
            boolean listening = BridgeState.start(context);
            WifiBridge.start(context); ConnectionService.ensure(context);
            // Result 0 is reported only when the Mac can actually reach the bridge.
            setResultCode(listening ? 0 : 2);
        } else if ("local.androidwireless.bridge.TEST".equals(intent.getAction())) {
            MainActivity.postTest(context); setResultCode(0);
        } else if ("local.androidwireless.bridge.TEST_BRIDGE".equals(intent.getAction())) {
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
                event.put("title", "Android Wireless test");
                event.put("body", "Original phone app icon test. No message was sent.");
                event.put("time", System.currentTimeMillis()); event.put("icon", AppIcons.get(context, source));
                BridgeState.add(event); setResultCode(0);
            } catch (Exception ignored) { setResultCode(1); }
        }
    }
}
