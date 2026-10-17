package local.androidwireless.bridge;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.net.wifi.WifiManager;
import android.os.*;

/** Visible, restartable companion service. Locks expire when the Mac stops polling. */
public final class ConnectionService extends Service {
    private static volatile long leaseUntil;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock wake;
    private WifiManager.WifiLock wifi;
    private WifiManager.WifiLock lowLatency;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback network;
    static void clientActive() { leaseUntil = SystemClock.elapsedRealtime() + 45000; }
    static void ensure(Context context) {
        if (context.getSharedPreferences("bridge", 0).getString("token", "").length() != 64) return;
        try { context.startForegroundService(new Intent(context, ConnectionService.class)); }
        catch (RuntimeException error) { android.util.Log.w("AndroidWireless", "Open app to enable background connection", error); }
    }
    private final Runnable maintain = new Runnable() {
        public void run() {
            boolean active = SystemClock.elapsedRealtime() < leaseUntil;
            if (active) {
                wake.acquire(60000);
                if (!wifi.isHeld()) wifi.acquire();
                if (lowLatency != null && !lowLatency.isHeld()) lowLatency.acquire();
            } else {
                if (wake.isHeld()) wake.release();
                if (wifi.isHeld()) wifi.release();
                if (lowLatency != null && lowLatency.isHeld()) lowLatency.release();
            }
            handler.postDelayed(this, 10000);
        }
    };
    @Override public void onCreate() {
        super.onCreate();
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("wireless-connection", "Mac connection", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent copy = PendingIntent.getActivity(this, 1,
            new Intent(this, ClipboardActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(this, "wireless-connection")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim).setContentTitle("Android Wireless")
            .setContentText("Connected to your Mac · copy something, then tap Copy to Mac")
            .addAction(new Notification.Action.Builder(null, "Copy to Mac", copy).build())
            .setContentIntent(open).setOngoing(true).setShowWhen(false).build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(2001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(2001, notification);
        wake = ((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AndroidWireless:MacConnection");
        wake.setReferenceCounted(false);
        WifiManager wifiManager = (WifiManager)getApplicationContext().getSystemService(WIFI_SERVICE);
        wifi = createHighPerformanceLock(wifiManager);
        wifi.setReferenceCounted(false);
        if (Build.VERSION.SDK_INT >= 29) {
            // HIGH_PERF is deprecated on newer Android; LOW_LATENCY is its replacement.
            lowLatency = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "AndroidWireless:MacLowLatency");
            lowLatency.setReferenceCounted(false);
        }
        BridgeState.start(this); WifiBridge.start(this);
        connectivity = getSystemService(ConnectivityManager.class);
        network = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network available) { WifiBridge.start(ConnectionService.this); }
        };
        connectivity.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), network);
        handler.post(maintain);
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        // A sticky restart re-checks both listeners in case either stopped.
        BridgeState.start(this); WifiBridge.start(this);
        return START_STICKY;
    }

    @SuppressWarnings("deprecation")
    private static WifiManager.WifiLock createHighPerformanceLock(WifiManager manager) {
        return manager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "AndroidWireless:MacConnection");
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (wake.isHeld()) wake.release(); if (wifi.isHeld()) wifi.release();
        if (lowLatency != null && lowLatency.isHeld()) lowLatency.release();
        if (network != null) connectivity.unregisterNetworkCallback(network);
        super.onDestroy();
    }
}
