package com.johirulhoqakash.jhmirror;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity {
    private PhoneUi ui;
    private LinearLayout content;
    private TextView connection, queueLabel;
    private final TextView[] featureLabels = new TextView[DeviceStatus.IDS.length];
    private final TextView[] featureReasons = new TextView[DeviceStatus.IDS.length];
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private boolean readingQueue;
    private int tab;
    private final Button[] tabs = new Button[3];
    private final Runnable refresh = new Runnable() {
        @Override public void run() { refreshStatus(); handler.postDelayed(this, 3000); }
    };
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); BridgeState.start(this); ConnectionService.ensure(this); ui = new PhoneUi(this);
        if (saved != null) tab = saved.getInt("tab", 0);
        LinearLayout root = ui.column(); root.setBackgroundColor(ui.background);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom()); return insets.consumeSystemWindowInsets();
        });
        getWindow().setStatusBarColor(ui.background); getWindow().setNavigationBarColor(ui.surface);
        getWindow().getDecorView().setSystemUiVisibility(ui.dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        LinearLayout header = ui.column(); header.setPadding(ui.dp(22), ui.dp(12), ui.dp(22), ui.dp(12));
        header.addView(ui.text("JH Mirror", 27, true)); header.addView(ui.note("Your phone. Your Mac. One connection.")); root.addView(header);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.setClipToPadding(false);
        content = ui.column(); content.setPadding(ui.dp(18), ui.dp(8), ui.dp(18), ui.dp(16)); scroll.addView(content);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout nav = new LinearLayout(this); nav.setPadding(ui.dp(12), ui.dp(4), ui.dp(12), ui.dp(4)); nav.setBackgroundColor(ui.surface);
        String[] labels = {"Home", "Device check", "Settings"};
        for (int i = 0; i < labels.length; i++) { final int index = i;
            Button button = ui.button(labels[i], () -> { tab = index; showTab(); }); button.setContentDescription(labels[i]);
            tabs[i] = button; button.setTextSize(12);
            nav.addView(button, new LinearLayout.LayoutParams(0, ui.dp(56), 1));
        }
        root.addView(nav); setContentView(root); showTab();
        if ((getPackageName() + ".PICK_FILES").equals(getIntent().getAction())) { startActivity(new Intent(this, PickFilesActivity.class)); finish(); }
    }
    @Override protected void onSaveInstanceState(Bundle state) { state.putInt("tab", tab); super.onSaveInstanceState(state); }
    private void showTab() {
        for (int i = 0; i < tabs.length; i++) if (tabs[i] != null) ui.styleButton(tabs[i], i == tab);
        content.removeAllViews(); connection = null; queueLabel = null;
        java.util.Arrays.fill(featureLabels, null); java.util.Arrays.fill(featureReasons, null);
        if (tab == 0) home(); else if (tab == 1) device(); else settings();
        refreshStatus();
    }
    private void home() {
        LinearLayout card = ui.card(content); connection = ui.text("Checking connection…", 19, true); card.addView(connection);
        card.addView(ui.note(Build.MANUFACTURER + " " + Build.MODEL + " · Android " + Build.VERSION.RELEASE));
        card.addView(ui.note("Connect JH Mirror on your paired Mac. Transfers continue without keeping this screen open."));
        LinearLayout actions = ui.card(content); ui.heading(actions, "Quick actions");
        actions.addView(ui.button("Send files to Mac", () -> startActivity(new Intent(this, PickFilesActivity.class))));
        actions.addView(ui.button("Copy clipboard to Mac", () -> startActivity(new Intent(this, ClipboardActivity.class))));
        actions.addView(ui.note("You can also share photos or files from any app → JH Mirror. Your originals stay on the phone."));
        LinearLayout transfers = ui.card(content); ui.heading(transfers, "Transfers"); queueLabel = ui.note("Reading queue…"); transfers.addView(queueLabel);
        transfers.addView(ui.note("Mac destination: Downloads / JH Mirror. A file is complete only after the Mac verifies it."));
        LinearLayout check = ui.card(content); ui.heading(check, "Know what works on this phone");
        check.addView(ui.note("See a separate signal for mirroring, files, gallery, calls, screen off and notifications."));
        check.addView(ui.button("Open device checklist", () -> { tab = 1; showTab(); }));
        content.addView(ui.note("JH Mirror " + version() + " · Johirul Hoq Akash"));
    }
    private void device() {
        content.addView(ui.text("Device check", 23, true));
        content.addView(ui.note(Build.MANUFACTURER + " " + Build.MODEL + " · Android " + Build.VERSION.RELEASE));
        content.addView(ui.note("Green: checked or active  ·  Yellow: setup / not checked  ·  Red: failed / unsupported. Tap a feature for its reason and next step."));
        for (int i = 0; i < DeviceStatus.IDS.length; i++) {
            final int index = i; LinearLayout card = ui.card(content); ui.heading(card, DeviceStatus.TITLES[i]);
            featureLabels[i] = ui.text("Not checked", 13, true); card.addView(featureLabels[i]);
            featureReasons[i] = ui.note(""); card.addView(featureReasons[i]);
            card.setOnClickListener(v -> explain(index)); card.setFocusable(true); card.setContentDescription(DeviceStatus.TITLES[i] + ", details");
        }
        content.addView(ui.button("Refresh status", this::refreshStatus));
        content.addView(ui.note("Mac checks never start your camera or microphone. Unsupported features do not prevent other features from working."));
    }
    private void explain(int index) {
        JSONObject item = DeviceStatus.rows(this).optJSONObject(index); if (item == null) return;
        new AlertDialog.Builder(this).setTitle(DeviceStatus.TITLES[index] + " · " + item.optString("label"))
            .setMessage(item.optString("reason") + "\n\n" + item.optString("nextStep")).setPositiveButton("OK", null).show();
    }
    private void settings() {
        content.addView(ui.text("Settings", 23, true));
        LinearLayout transfers = ui.card(content); ui.heading(transfers, "Quiet transfers");
        toggle(transfers, "Return to my app after sharing", "quietShares", true, null);
        transfers.addView(ui.note("Return automatically after files are safely queued. Preparation and errors remain visible. No dashboard opens after a transfer."));
        LinearLayout notifications = ui.card(content); ui.heading(notifications, "Notifications");
        toggle(notifications, "Send notifications to Mac", "enabled", true, () -> { if (!getSharedPreferences("bridge", 0).getBoolean("enabled", true)) BridgeState.clear(); });
        notifications.addView(ui.button("Notification access", () -> openSetting(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))));
        notifications.addView(ui.button("App notification settings", () -> openSetting(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()))));
        notifications.addView(ui.button("Send test notification", this::testNotification));
        LinearLayout connection = ui.card(content); ui.heading(connection, "Connection & battery");
        connection.addView(ui.button(Build.VERSION.SDK_INT >= 30 ? "Wireless / USB debugging settings" : "USB debugging settings", () -> openSetting(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))));
        connection.addView(ui.note(Build.VERSION.SDK_INT >= 30 ? "Wireless pairing needs the same Wi-Fi. Reconnect from the Mac menu if needed." : "This Android version has no QR wireless pairing. Use a USB cable and approve USB debugging on the phone."));
        connection.addView(ui.button("Battery optimization settings", () -> openSetting(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))));
        LinearLayout appearance = ui.card(content); ui.heading(appearance, "Appearance");
        appearance.addView(ui.button("Theme: " + getSharedPreferences("bridge", 0).getString("uiTheme", "system"), () -> {
            String[] values = {"system", "light", "dark"}; int selected = java.util.Arrays.asList(values).indexOf(getSharedPreferences("bridge", 0).getString("uiTheme", "system"));
            new AlertDialog.Builder(this).setTitle("Appearance").setSingleChoiceItems(new String[]{"Follow phone", "Light", "Dark"}, selected, (dialog, which) -> {
                getSharedPreferences("bridge", 0).edit().putString("uiTheme", values[which]).apply(); dialog.dismiss(); recreate();
            }).setNegativeButton("Cancel", null).show();
        }));
        appearance.addView(ui.button("Privacy & app information", () -> new AlertDialog.Builder(this).setTitle("JH Mirror " + version())
            .setMessage("Notifications and selected files travel over your authorized ADB connection or encrypted, paired Wi-Fi. Android may hide sensitive notifications. Camera and microphone start only from Mac controls. No cloud account or analytics service is used. Withdraw access by unpairing the Mac in debugging settings.\n\nDeveloped by Johirul Hoq Akash.").setPositiveButton("OK", null).show()));
    }
    private void toggle(LinearLayout parent, String label, String key, boolean fallback, Runnable changed) {
        Switch control = new Switch(this); control.setText(label); control.setTextColor(ui.text); control.setTextSize(14); control.setPadding(0, ui.dp(10), 0, ui.dp(10));
        control.setChecked(getSharedPreferences("bridge", 0).getBoolean(key, fallback));
        control.setOnCheckedChangeListener((view, enabled) -> { getSharedPreferences("bridge", 0).edit().putBoolean(key, enabled).apply(); if (changed != null) changed.run(); }); parent.addView(control);
    }
    private void openSetting(Intent intent) {
        try { startActivity(intent); } catch (RuntimeException missing) { Toast.makeText(this, "This setting is unavailable on this phone. Open it from phone Settings.", Toast.LENGTH_LONG).show(); }
    }
    private void testNotification() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        else postTest(this);
    }
    private void refreshStatus() {
        if (connection != null) {
            boolean paired = getSharedPreferences("bridge", 0).getString("token", "").length() == 64;
            connection.setText(ConnectionService.isClientActive() ? "● Connected to your Mac" : paired ? "● Waiting for your Mac" : "● Pair from your Mac");
            connection.setTextColor(ui.signal(ConnectionService.isClientActive() ? "green" : "yellow"));
        }
        JSONArray rows = DeviceStatus.rows(this);
        for (int i = 0; i < featureLabels.length; i++) if (featureLabels[i] != null) {
            JSONObject row = rows.optJSONObject(i); if (row == null) continue;
            featureLabels[i].setText("● " + row.optString("label")); featureLabels[i].setTextColor(ui.signal(row.optString("state"))); featureReasons[i].setText(row.optString("reason"));
        }
        if (queueLabel != null && !readingQueue) {
            readingQueue = true; worker.execute(() -> {
                JSONArray queue = FileOutbox.list(this); long bytes = 0;
                for (int i = 0; i < queue.length(); i++) bytes += queue.optJSONObject(i).optLong("size");
                final String message = (queue.length() == 0 ? "No files waiting" : queue.length() + " file(s) waiting · " + android.text.format.Formatter.formatShortFileSize(this, bytes))
                    + "\nLast verified by Mac: " + getSharedPreferences("bridge", 0).getString("lastFileSent", "None yet");
                runOnUiThread(() -> { readingQueue = false; if (queueLabel != null) queueLabel.setText(message); });
            });
        }
    }
    private String version() { try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception e) { return ""; } }
    @Override public void onResume() { super.onResume(); handler.removeCallbacks(refresh); handler.post(refresh); }
    @Override public void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onDestroy() { worker.shutdownNow(); super.onDestroy(); }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == 1 && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) postTest(this);
    }
    static void postTest(Context context) { postTest(context, "Your phone notification reached the Mac. Try Reply or Mark as read there."); }

    /** A chat-style test notification: tap opens JH Mirror, Reply takes text, Mark as read clears it. */
    static void postTest(Context context, String text) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        NotificationManager manager = (NotificationManager)context.getSystemService(NOTIFICATION_SERVICE);
        manager.createNotificationChannel(new NotificationChannel("wireless-test", "Connection tests", NotificationManager.IMPORTANCE_DEFAULT));
        Bundle extras = new Bundle(); extras.putBoolean("wireless_test", true);
        PendingIntent open = PendingIntent.getActivity(context, 20, new Intent(context, MainActivity.class),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent replyIntent = new Intent(context, TestActionReceiver.class).setAction(TestActionReceiver.REPLY);
        // Mutable so Android can add the typed reply.
        PendingIntent reply = PendingIntent.getBroadcast(context, 21, replyIntent,
            (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0) | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent read = PendingIntent.getBroadcast(context, 22,
            new Intent(context, TestActionReceiver.class).setAction(TestActionReceiver.READ),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        RemoteInput input = new RemoteInput.Builder(TestActionReceiver.KEY_TEXT).setLabel("Reply").build();
        Notification test = new Notification.Builder(context, "wireless-test")
            .setSmallIcon(android.R.drawable.stat_notify_chat).setContentTitle("JH Mirror test")
            .setContentText(text).setStyle(new Notification.BigTextStyle().bigText(text))
            .setContentIntent(open).setAutoCancel(true).addExtras(extras)
            .addAction(new Notification.Action.Builder(null, "Reply", reply).addRemoteInput(input).build())
            .addAction(new Notification.Action.Builder(null, "Mark as read", read).build())
            .build();
        manager.notify(TestActionReceiver.ID, test);
    }
}
