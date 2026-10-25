package com.johirulhoqakash.jhmirror;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;

/**
 * Sends the phone's current clipboard (image, file or text) to the Mac clipboard.
 * Android 10+ lets only the focused app read the clipboard, so this transparent
 * activity reads it once it gains window focus, queues it, and closes.
 */
public final class ClipboardActivity extends Activity {
    private boolean handled;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        BridgeState.start(this);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || handled) return;
        handled = true;
        ClipData clip = null;
        try { clip = ((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).getPrimaryClip(); }
        catch (RuntimeException ignored) { }
        if (clip == null || clip.getItemCount() == 0) { done("Phone clipboard is empty. Copy an image or text first."); return; }
        ClipData.Item item = clip.getItemAt(0);
        Uri uri = item.getUri();
        CharSequence text = uri == null ? item.coerceToText(this) : null;
        if (uri == null && (text == null || text.length() == 0)) { done("Nothing to copy to the Mac."); return; }
        Toast.makeText(this, "Copying to your Mac…", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String message;
            try {
                if (uri != null) FileOutbox.stage(this, uri, FileOutbox.CLIPBOARD, progress -> { });
                else FileOutbox.stageText(this, text, progress -> { });
                message = "Copied to Mac · press ⌘V on the Mac to paste";
            } catch (Exception e) {
                message = "Could not copy to Mac: " + e.getMessage();
            }
            final String result = message;
            runOnUiThread(() -> done(result));
        }, "clipboard-to-mac").start();
    }

    private void done(String message) {
        Toast.makeText(getApplicationContext(), message, Toast.LENGTH_LONG).show();
        finish();
    }
}
