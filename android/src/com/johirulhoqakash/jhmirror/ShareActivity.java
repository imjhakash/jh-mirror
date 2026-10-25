package com.johirulhoqakash.jhmirror;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Parcelable;
import android.view.WindowManager;
import android.widget.*;
import java.util.ArrayList;

/** Share → JH Mirror queues files. Share → Copy to Mac also places them on the Mac clipboard. */
public final class ShareActivity extends Activity {
    static final String COPY_TO_MAC = "com.johirulhoqakash.jhmirror.CopyToMac";

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        Intent intent = getIntent();
        boolean clipboard = intent.getComponent() != null && COPY_TO_MAC.equals(intent.getComponent().getClassName());
        PhoneUi ui = new PhoneUi(this);
        LinearLayout layout = ui.column(); layout.setPadding(ui.dp(22), ui.dp(20), ui.dp(22), ui.dp(18)); layout.setBackground(ui.rounded(ui.surface, 20));
        layout.addView(ui.text(clipboard ? "Copy to Mac" : "Send to your Mac", 22, true));
        TextView status = ui.note(""); layout.addView(status);
        Button done = ui.button("Done", this::finish); done.setEnabled(false); layout.addView(done);
        setContentView(layout); getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        ArrayList<Uri> files = new ArrayList<>();
        CharSequence text = null;
        try {
            if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
                ArrayList<? extends Parcelable> shared = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Parcelable.class)
                    : legacyStreams(intent);
                if (shared != null) for (Parcelable value : shared) if (value instanceof Uri) files.add((Uri)value);
            } else if (Intent.ACTION_SEND.equals(intent.getAction())) {
                Parcelable value = Build.VERSION.SDK_INT >= 33
                    ? intent.getParcelableExtra(Intent.EXTRA_STREAM, Parcelable.class)
                    : legacyStream(intent);
                if (value instanceof Uri) files.add((Uri)value);
                else text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
            } else if ("com.johirulhoqakash.jhmirror.PICKED".equals(intent.getAction())) {
                if (intent.getClipData() != null) for (int i = 0; i < intent.getClipData().getItemCount(); i++) files.add(intent.getClipData().getItemAt(i).getUri());
                else if (intent.getData() != null) files.add(intent.getData());
            }
            if (files.isEmpty() && text == null && intent.getClipData() != null) {
                ClipData clip = intent.getClipData();
                for (int i = 0; i < clip.getItemCount(); i++) {
                    Uri uri = clip.getItemAt(i).getUri(); if (uri != null) files.add(uri);
                }
            }
        } catch (RuntimeException e) { files.clear(); text = null; }
        files.removeIf(uri -> uri == null);
        if (clipboard && files.isEmpty() && text != null && text.length() > 0) {
            final CharSequence copied = text;
            BridgeState.start(this);
            status.setText("Copying text to your Mac…");
            new Thread(() -> finishWith(status, done, () -> FileOutbox.stageText(this, copied, message -> runOnUiThread(() -> status.setText(message)))),
                "prepare-clipboard-text").start();
            return;
        }
        // The Mac clipboard holds one item; several files are still delivered and the last one is copied.
        if (files.isEmpty() || files.size() > FileOutbox.MAX_QUEUE) {
            status.setText(clipboard ? "Choose a photo, file or text, then Share → Copy to Mac."
                : "Choose 1–100 files or photos, then Share → JH Mirror.");
            done.setEnabled(true); return;
        }
        BridgeState.start(this);
        status.setText("Preparing " + files.size() + " file(s)… Keep this screen open until preparation completes.");
        new Thread(() -> {
            int queued = 0; int failed = 0; String error = "";
            for (int i = 0; i < files.size(); i++) {
                Uri uri = files.get(i);
                // Only the final item goes to the clipboard so a multi-select paste is predictable.
                String purpose = clipboard && i == files.size() - 1 ? FileOutbox.CLIPBOARD : null;
                try {
                    FileOutbox.stage(this, uri, purpose, message -> runOnUiThread(() -> status.setText(message)));
                    queued++;
                } catch (Exception e) { failed++; error = e.getMessage(); }
            }
            String message = (clipboard && failed == 0
                    ? queued + " file(s) queued. The last item goes to the Mac clipboard after transfer."
                    : queued + " file(s) queued for your Mac." + (failed == 0 ? "" : "\n" + failed + " failed: " + error))
                + "\n\nReceived files also appear in Downloads / JH Mirror on the Mac. Original files remain on your phone.";
            final boolean success = failed == 0;
            runOnUiThread(() -> { status.setText(message); done.setEnabled(true); getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); if (success) finishQuietly(); });
        }, "prepare-shared-files").start();
    }

    interface Job { void run() throws Exception; }

    private void finishWith(TextView status, Button done, Job job) {
        String message;
        try { job.run(); message = null; }
        catch (Exception e) { message = "Could not copy: " + e.getMessage(); }
        final String failure = message;
        runOnUiThread(() -> {
            if (failure != null) status.setText(failure);
            else { status.setText("Text queued for your Mac clipboard. Paste after it arrives on the Mac."); finishQuietly(); }
            done.setEnabled(true); getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        });
    }

    private void finishQuietly() {
        if (!getSharedPreferences("bridge", 0).getBoolean("quietShares", true)) return;
        Toast.makeText(this, "Queued for your Mac · originals kept", Toast.LENGTH_SHORT).show();
        finish();
    }

    @SuppressWarnings("deprecation")
    private static ArrayList<Parcelable> legacyStreams(Intent intent) { return intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM); }

    @SuppressWarnings("deprecation")
    private static Parcelable legacyStream(Intent intent) { return intent.getParcelableExtra(Intent.EXTRA_STREAM); }
}
