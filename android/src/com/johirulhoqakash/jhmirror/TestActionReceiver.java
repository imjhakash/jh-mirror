package com.johirulhoqakash.jhmirror;

import android.app.NotificationManager;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/** Handles the buttons on the JH Mirror test notification, to show replies from the Mac working. */
public final class TestActionReceiver extends BroadcastReceiver {
    static final String REPLY = "com.johirulhoqakash.jhmirror.TEST_REPLY";
    static final String READ = "com.johirulhoqakash.jhmirror.TEST_READ";
    static final String KEY_TEXT = "reply";
    static final int ID = 1001;

    @Override public void onReceive(Context context, Intent intent) {
        if (REPLY.equals(intent.getAction())) {
            Bundle results = RemoteInput.getResultsFromIntent(intent);
            CharSequence text = results == null ? null : results.getCharSequence(KEY_TEXT);
            Log.i("JHMirror", "Test reply received (" + (text == null ? 0 : text.length()) + " characters)");
            MainActivity.postTest(context, "You replied: " + (text == null ? "" : text));
        } else if (READ.equals(intent.getAction())) {
            Log.i("JHMirror", "Test notification marked as read");
            ((NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE)).cancel(ID);
        }
    }
}
