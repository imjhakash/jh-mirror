package local.androidwireless.bridge;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.provider.Settings;
import android.graphics.Color;
import android.widget.*;

public final class MainActivity extends Activity {
    private TextView status;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            boolean configured = getSharedPreferences("bridge", 0).getString("token", "").length() == 64;
            status.setText((BridgeState.listenerConnected ? "Notification access: connected" : "Notification access: waiting for permission")
                + "\n" + (configured ? "Encrypted Wi-Fi: configured" : "Open Android Wireless on your Mac to connect")
                + "\nFiles waiting for Mac: " + FileOutbox.list(MainActivity.this).length()
                + "\nLast received by Mac: " + getSharedPreferences("bridge", 0).getString("lastFileSent", "None yet"));
            handler.postDelayed(this, 1500);
        }
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); BridgeState.start(this); ConnectionService.ensure(this);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int)(24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding * 2, padding, padding);
        layout.setBackgroundColor(Color.rgb(247, 249, 252));
        TextView title = new TextView(this); title.setText("Android Wireless"); title.setTextSize(28); title.setTextColor(Color.rgb(24, 35, 52));
        layout.addView(title);
        TextView description = new TextView(this); description.setTextSize(16);
        description.setText("Send notifications and selected files to your paired Mac over encrypted Wi-Fi. Keep Android Wireless running on the Mac. Wireless debugging is needed for screen mirroring and control.\n\nNotification access lets this app read message titles and content. They travel through an encrypted connection trusted during Mac pairing. This app keeps recent events in memory; Mac Notification Center may retain displayed alerts. Android may hide sensitive messages such as OTPs.\n");
        layout.addView(description);
        status = new TextView(this); status.setTextSize(15); layout.addView(status);
        Button files = new Button(this); files.setText("Choose files to send to Mac");
        files.setOnClickListener(v -> chooseFiles()); layout.addView(files);
        TextView fileHelp = new TextView(this);
        fileHelp.setText("Or select files/photos in another app → Share → Android Wireless. Original files stay on your phone. Your Mac saves them in Downloads / Android Wireless.\n");
        layout.addView(fileHelp);
        Button access = new Button(this); access.setText("Enable notification access");
        access.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)));
        layout.addView(access);
        Switch pause = new Switch(this); pause.setText("Send notifications to Mac");
        pause.setChecked(getSharedPreferences("bridge", 0).getBoolean("enabled", true));
        pause.setOnCheckedChangeListener((view, enabled) -> {
            getSharedPreferences("bridge", 0).edit().putBoolean("enabled", enabled).apply();
            if (!enabled) BridgeState.clear();
        }); layout.addView(pause);
        Button test = new Button(this); test.setText("Send test notification");
        test.setOnClickListener(v -> {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
            else postTest(this);
        }); layout.addView(test);
        ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
        handlePickerRequest();
    }
    private void chooseFiles() {
        Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        picker.addCategory(Intent.CATEGORY_OPENABLE); picker.setType("*/*");
        picker.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true); startActivityForResult(picker, 2);
    }
    private void handlePickerRequest() {
        if ("local.androidwireless.bridge.PICK_FILES".equals(getIntent().getAction())) {
            getIntent().setAction(Intent.ACTION_MAIN); chooseFiles();
        }
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent); handlePickerRequest();
    }
    @Override public void onResume() { super.onResume(); handler.post(refresh); }
    @Override public void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    @Override public void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == 2 && result == RESULT_OK && data != null) {
            Intent share = new Intent(this, ShareActivity.class).setAction("local.androidwireless.bridge.PICKED");
            share.setData(data.getData()); share.setClipData(data.getClipData());
            share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivity(share);
        }
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == 1 && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) postTest(this);
    }
    static void postTest(Context context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        NotificationManager manager = (NotificationManager)context.getSystemService(NOTIFICATION_SERVICE);
        manager.createNotificationChannel(new NotificationChannel("wireless-test", "Connection tests", NotificationManager.IMPORTANCE_DEFAULT));
        Bundle extras = new Bundle(); extras.putBoolean("wireless_test", true);
        Notification test = new Notification.Builder(context, "wireless-test")
            .setSmallIcon(android.R.drawable.stat_notify_chat).setContentTitle("Android Wireless test")
            .setContentText("Your phone notification reached the Mac.").addExtras(extras).setAutoCancel(true).build();
        manager.notify(1001, test);
    }
}
