package local.androidwireless.bridge;

import android.app.Notification;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import org.json.JSONObject;

public final class NotificationBridge extends NotificationListenerService {
    @Override public void onCreate() { super.onCreate(); BridgeState.start(this); ConnectionService.ensure(this); }
    @Override public void onListenerConnected() { BridgeState.listenerConnected = true; }
    @Override public void onListenerDisconnected() { BridgeState.listenerConnected = false; }
    @Override public void onDestroy() { BridgeState.listenerConnected = false; super.onDestroy(); }

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        Notification n = sbn.getNotification();
        if (!BridgeState.enabled() || (n.flags & (Notification.FLAG_ONGOING_EVENT | Notification.FLAG_GROUP_SUMMARY)) != 0) return;
        Bundle extras = n.extras;
        if (sbn.getPackageName().equals(getPackageName()) && !extras.getBoolean("wireless_test", false)) return;
        try {
            String app = sbn.getPackageName();
            try { app = getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(app, 0)).toString(); }
            catch (Exception ignored) { }
            CharSequence title = extras.getCharSequence(Notification.EXTRA_TITLE, "");
            CharSequence text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
            if (text == null) text = extras.getCharSequence(Notification.EXTRA_TEXT, "");
            JSONObject item = new JSONObject();
            item.put("type", "posted"); item.put("key", sbn.getKey());
            item.put("package", sbn.getPackageName()); item.put("app", app);
            item.put("icon", AppIcons.get(this, sbn.getPackageName()));
            item.put("title", limit(title)); item.put("body", limit(text));
            item.put("time", sbn.getPostTime());
            BridgeState.add(item);
        } catch (Exception ignored) { }
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        try {
            JSONObject item = new JSONObject(); item.put("type", "removed");
            item.put("key", sbn.getKey()); BridgeState.add(item);
        } catch (Exception ignored) { }
    }

    private static String limit(CharSequence value) {
        String text = value == null ? "" : value.toString();
        return text.substring(0, Math.min(text.length(), 4000));
    }
}
