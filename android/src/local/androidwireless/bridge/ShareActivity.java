package local.androidwireless.bridge;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Parcelable;
import android.view.WindowManager;
import android.widget.*;
import java.util.ArrayList;

public final class ShareActivity extends Activity {
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(24 * getResources().getDisplayMetrics().density); layout.setPadding(pad, pad * 2, pad, pad);
        TextView title = new TextView(this); title.setText("Send to your Mac"); title.setTextSize(26); layout.addView(title);
        TextView status = new TextView(this); status.setTextSize(16); layout.addView(status);
        Button done = new Button(this); done.setText("Done"); done.setEnabled(false); done.setOnClickListener(v -> finish()); layout.addView(done);
        setContentView(layout); getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        ArrayList<Uri> files = new ArrayList<>();
        Intent intent = getIntent();
        try {
            if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
                ArrayList<Parcelable> shared = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (shared != null) for (Parcelable value : shared) if (value instanceof Uri) files.add((Uri)value);
            } else if (Intent.ACTION_SEND.equals(intent.getAction())) {
                Parcelable value = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                if (value instanceof Uri) files.add((Uri)value);
            } else if ("local.androidwireless.bridge.PICKED".equals(intent.getAction())) {
                if (intent.getClipData() != null) for (int i = 0; i < intent.getClipData().getItemCount(); i++) files.add(intent.getClipData().getItemAt(i).getUri());
                else if (intent.getData() != null) files.add(intent.getData());
            }
            if (files.isEmpty() && intent.getClipData() != null)
                for (int i = 0; i < intent.getClipData().getItemCount(); i++) {
                    Uri uri = intent.getClipData().getItemAt(i).getUri(); if (uri != null) files.add(uri);
                }
        } catch (RuntimeException e) { files.clear(); }
        if (files.isEmpty() || files.size() > 100) {
            status.setText("Choose 1–100 files or photos, then Share → Android Wireless."); done.setEnabled(true); return;
        }
        BridgeState.start(this);
        status.setText("Preparing " + files.size() + " file(s)… Keep this screen open until preparation completes.");
        new Thread(() -> {
            int queued = 0; int failed = 0; String error = "";
            for (Uri uri : files) {
                try {
                    FileOutbox.stage(this, uri, message -> runOnUiThread(() -> status.setText(message)));
                    queued++;
                } catch (Exception e) { failed++; error = e.getMessage(); }
            }
            String message = queued + " file(s) queued for your Mac." + (failed == 0 ? "" : "\n" + failed + " failed: " + error)
                + "\n\nOpen Android Wireless on your Mac. Received files appear in Downloads / Android Wireless. Original files remain on your phone.";
            runOnUiThread(() -> { status.setText(message); done.setEnabled(true); getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); });
        }, "prepare-shared-files").start();
    }
}
