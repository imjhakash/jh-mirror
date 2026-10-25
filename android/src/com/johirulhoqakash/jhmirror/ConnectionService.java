package com.johirulhoqakash.jhmirror;

import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.net.wifi.WifiManager;
import android.os.*;
import android.telephony.TelephonyManager;
import org.json.JSONObject;

/** Visible, restartable companion service. Locks expire when the Mac stops polling. */
public final class ConnectionService extends Service {
    private static volatile long leaseUntil;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock wake;
    private WifiManager.WifiLock wifi;
    private WifiManager.WifiLock lowLatency;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback network;
    private TelephonyManager telephony;
    @SuppressWarnings("deprecation")
    private android.telephony.PhoneStateListener phoneListener;
    private Object telephonyCallback; // TelephonyCallback on API 31+
    private static volatile boolean callRingingSent = false;
    static void clientActive() { leaseUntil = SystemClock.elapsedRealtime() + 45000; }
    static boolean isClientActive() { return SystemClock.elapsedRealtime() < leaseUntil; }
    static void ensure(Context context) {
        if (context.getSharedPreferences("bridge", 0).getString("token", "").length() != 64) return;
        try { context.startForegroundService(new Intent(context, ConnectionService.class)); }
        catch (RuntimeException error) { android.util.Log.w("JHMirror", "Open app to enable background connection", error); }
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
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim).setContentTitle("JH Mirror")
            .setContentText("Ready for your paired Mac · tap Copy to Mac when needed")
            .addAction(new Notification.Action.Builder(null, "Copy to Mac", copy).build())
            .setContentIntent(open).setOngoing(true).setShowWhen(false).build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(2001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        else startForeground(2001, notification);
        wake = ((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "JHMirror:MacConnection");
        wake.setReferenceCounted(false);
        WifiManager wifiManager = (WifiManager)getApplicationContext().getSystemService(WIFI_SERVICE);
        wifi = createHighPerformanceLock(wifiManager);
        wifi.setReferenceCounted(false);
        if (Build.VERSION.SDK_INT >= 29) {
            // HIGH_PERF is deprecated on newer Android; LOW_LATENCY is its replacement.
            lowLatency = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "JHMirror:MacLowLatency");
            lowLatency.setReferenceCounted(false);
        }
        BridgeState.start(this); WifiBridge.start(this);
        connectivity = getSystemService(ConnectivityManager.class);
        network = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network available) { WifiBridge.start(ConnectionService.this); }
        };
        connectivity.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), network);
        try { registerPhoneListener(); } catch (Exception e) { android.util.Log.w("JHMirror", "Phone listener unavailable", e); }
        handler.post(maintain);
    }

    @SuppressWarnings("deprecation")
    private void registerPhoneListener() {
        String perm = Build.VERSION.SDK_INT >= 33
            ? "android.permission.READ_BASIC_PHONE_STATE"
            : "android.permission.READ_PHONE_STATE";
        if (checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) return;
        telephony = (TelephonyManager) getSystemService(TELEPHONY_SERVICE);
        if (telephony == null) return;
        if (Build.VERSION.SDK_INT >= 31) {
            registerCallbackApi31();
        } else {
            phoneListener = new android.telephony.PhoneStateListener() {
                @Override public void onCallStateChanged(int state, String number) {
                    handleCallState(state, number);
                }
            };
            telephony.listen(phoneListener, android.telephony.PhoneStateListener.LISTEN_CALL_STATE);
        }
    }

    private void registerCallbackApi31() {
        CallStateCb cb = new CallStateCb();
        telephonyCallback = cb;
        telephony.registerTelephonyCallback(getMainExecutor(), cb);
    }

    private void handleCallState(int state, String number) {
        if (state == TelephonyManager.CALL_STATE_RINGING) {
            callRingingSent = true;
            emitCallEvent("call_ringing", number);
        } else if (callRingingSent &&
                   (state == TelephonyManager.CALL_STATE_OFFHOOK || state == TelephonyManager.CALL_STATE_IDLE)) {
            callRingingSent = false;
            emitCallEvent("removed", null);
        }
    }

    private final class CallStateCb extends android.telephony.TelephonyCallback
            implements android.telephony.TelephonyCallback.CallStateListener {
        @Override public void onCallStateChanged(int state) { handleCallState(state, null); }
    }

    private void emitCallEvent(String type, String number) {
        try {
            JSONObject item = new JSONObject();
            item.put("type", type);
            item.put("key", "__phone_call__");
            if ("call_ringing".equals(type)) {
                item.put("package", "com.android.phone");
                item.put("app", "Phone");
                item.put("title", (number != null && !number.isEmpty()) ? number : "Incoming call");
                item.put("body", "");
                item.put("time", System.currentTimeMillis());
            }
            BridgeState.add(item);
        } catch (Exception ignored) {}
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        // A sticky restart re-checks both listeners in case either stopped.
        BridgeState.start(this); WifiBridge.start(this);
        return START_STICKY;
    }

    @SuppressWarnings("deprecation")
    private static WifiManager.WifiLock createHighPerformanceLock(WifiManager manager) {
        return manager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "JHMirror:MacConnection");
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @SuppressWarnings("deprecation")
    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (wake.isHeld()) wake.release(); if (wifi.isHeld()) wifi.release();
        if (lowLatency != null && lowLatency.isHeld()) lowLatency.release();
        if (network != null) connectivity.unregisterNetworkCallback(network);
        if (Build.VERSION.SDK_INT >= 31 && telephony != null && telephonyCallback != null)
            telephony.unregisterTelephonyCallback((android.telephony.TelephonyCallback) telephonyCallback);
        else if (telephony != null && phoneListener != null)
            telephony.listen(phoneListener, android.telephony.PhoneStateListener.LISTEN_NONE);
        super.onDestroy();
    }
}
