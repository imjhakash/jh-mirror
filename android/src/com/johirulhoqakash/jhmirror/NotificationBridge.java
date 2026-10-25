package com.johirulhoqakash.jhmirror;

import android.app.ActivityOptions;
import android.app.Notification;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.LruCache;
import org.json.JSONArray;
import org.json.JSONObject;

public final class NotificationBridge extends NotificationListenerService {
    /** The connected listener, used to act on notifications when the Mac asks. */
    private static volatile NotificationBridge instance;
    /** Recently posted notifications, so a tap on the Mac still works right after the phone removed it. */
    private static final LruCache<String, Notification> recent = new LruCache<>(120);
    private static final int MAX_ACTIONS = 3;

    @Override public void onCreate() { super.onCreate(); BridgeState.start(this); ConnectionService.ensure(this); }
    @Override public void onListenerConnected() { instance = this; BridgeState.listenerConnected = true; }
    @Override public void onListenerDisconnected() { instance = null; BridgeState.listenerConnected = false; }
    @Override public void onDestroy() { instance = null; BridgeState.listenerConnected = false; super.onDestroy(); }

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        Notification n = sbn.getNotification();
        if (!BridgeState.enabled() || (n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return;
        if ((n.flags & Notification.FLAG_ONGOING_EVENT) != 0) return;
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
            item.put("open", n.contentIntent != null);
            item.put("actions", describeActions(n));
            recent.put(sbn.getKey(), n);
            BridgeState.add(item);
        } catch (Exception ignored) { }
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        try {
            JSONObject item = new JSONObject(); item.put("type", "removed");
            item.put("key", sbn.getKey()); BridgeState.add(item);
        } catch (Exception ignored) { }
    }

    /** Buttons shown on the Mac, in the phone's order: [{title, input}] where input means a reply field. */
    private static JSONArray describeActions(Notification n) throws Exception {
        JSONArray result = new JSONArray();
        if (n.actions == null) return result;
        for (Notification.Action action : n.actions) {
            if (result.length() >= MAX_ACTIONS) break;
            if (action == null || action.actionIntent == null || action.title == null) { result.put(JSONObject.NULL); continue; }
            if (Build.VERSION.SDK_INT >= 29 && action.isContextual()) { result.put(JSONObject.NULL); continue; }
            JSONObject entry = new JSONObject();
            entry.put("title", limit(action.title));
            entry.put("input", acceptsText(action));
            result.put(entry);
        }
        return result;
    }

    private static boolean acceptsText(Notification.Action action) {
        RemoteInput[] inputs = action.getRemoteInputs();
        if (inputs == null) return false;
        for (RemoteInput input : inputs) if (input.getAllowFreeFormInput()) return true;
        return false;
    }

    private static Notification lookup(String key) {
        NotificationBridge listener = instance;
        if (listener != null) {
            try {
                StatusBarNotification[] active = listener.getActiveNotifications(new String[]{key});
                if (active != null && active.length > 0 && active[0] != null) return active[0].getNotification();
            } catch (RuntimeException ignored) { }
        }
        return recent.get(key);
    }

    /** Options that let the phone app open its screen even though JH Mirror runs in the background. */
    private static Bundle backgroundStart() {
        if (Build.VERSION.SDK_INT < 34) return null;
        ActivityOptions options = ActivityOptions.makeBasic();
        options.setPendingIntentBackgroundActivityStartMode(Build.VERSION.SDK_INT >= 36
            ? ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
            : legacyAllowedMode());
        return options.toBundle();
    }

    @SuppressWarnings("deprecation")
    private static int legacyAllowedMode() { return ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED; }

    private static void send(Context context, PendingIntent intent, Intent fill) throws PendingIntent.CanceledException {
        intent.send(context, 0, fill, null, null, null, backgroundStart());
    }

    /** Same as tapping the notification on the phone. Falls back to opening its app. */
    static String open(Context context, String key, String packageName) {
        Notification n = lookup(key);
        try {
            if (n != null && n.contentIntent != null) {
                send(context, n.contentIntent, null);
                NotificationBridge listener = instance;
                if (listener != null && (n.flags & Notification.FLAG_AUTO_CANCEL) != 0) listener.cancelNotification(key);
                return "opened";
            }
        } catch (PendingIntent.CanceledException ignored) {
            // The app replaced or withdrew it: open the app instead.
        }
        if (packageName != null && packageName.matches("[a-zA-Z0-9_.]{3,200}")) {
            Intent launch = context.getPackageManager().getLaunchIntentForPackage(packageName);
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try {
                    PendingIntent app = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
                    send(context, app, null);
                    return "app";
                } catch (PendingIntent.CanceledException ignored) { }
            }
        }
        return "gone";
    }

    /** Presses one of the notification's buttons; `text` fills its reply field. */
    static String action(Context context, String key, int index, String text) {
        Notification n = lookup(key);
        if (n == null || n.actions == null || index < 0 || index >= n.actions.length || n.actions[index] == null) return "gone";
        Notification.Action action = n.actions[index];
        if (action.actionIntent == null) return "gone";
        Intent fill = null;
        RemoteInput[] inputs = action.getRemoteInputs();
        if (inputs != null && inputs.length > 0) {
            if (text == null || text.trim().isEmpty()) return "needs-text";
            fill = new Intent();
            Bundle results = new Bundle();
            for (RemoteInput input : inputs) results.putCharSequence(input.getResultKey(), text);
            RemoteInput.addResultsToIntent(inputs, fill, results);
            if (Build.VERSION.SDK_INT >= 28) RemoteInput.setResultsSource(fill, RemoteInput.SOURCE_FREE_FORM_INPUT);
        }
        try {
            send(context, action.actionIntent, fill);
            return "done";
        } catch (PendingIntent.CanceledException e) {
            return "gone";
        }
    }

    /** Clears the notification on the phone, as when it is swiped away there. */
    static String dismiss(String key) {
        NotificationBridge listener = instance;
        if (listener == null) return "unavailable";
        try { listener.cancelNotification(key); return "done"; }
        catch (RuntimeException e) { return "gone"; }
    }

    private static String limit(CharSequence value) {
        String text = value == null ? "" : value.toString();
        return text.substring(0, Math.min(text.length(), 4000));
    }
}
