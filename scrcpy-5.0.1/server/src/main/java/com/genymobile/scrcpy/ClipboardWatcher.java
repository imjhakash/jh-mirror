// SPDX-License-Identifier: Apache-2.0
package com.genymobile.scrcpy;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.os.PersistableBundle;
import android.util.Base64;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * JH Mirror: reports phone clipboard changes to the Mac app.
 *
 * Started by the Mac over its authorized ADB connection as the shell user, which (unlike a
 * normal app on Android 10+) may observe the clipboard in the background. One line per event:
 *   AW_CLIP_READY
 *   AW_CLIP_TEXT <base64 utf-8 text>
 *   AW_CLIP_URI  <base64 mime> <base64 content uri>   (the Mac then reads it with `content read`)
 *   AW_CLIP_SKIPPED <reason>
 *   AW_CLIP_ERROR <message>
 * Reading the clip as the shell package also grants the shell read access to its content URI.
 * The process exits when the Mac closes its stdin.
 */
public final class ClipboardWatcher {
    private static final int MAX_TEXT_CHARS = 1_000_000;
    private static final String EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE";

    private ClipboardWatcher() {
        // not instantiable
    }

    public static void main(String... args) {
        int status = 0;
        try {
            Looper.prepareMainLooper();
            Workarounds.apply();
            ClipboardManager clipboard = (ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
            if (clipboard == null) {
                emit("AW_CLIP_ERROR " + encode("No clipboard service"));
                System.exit(2);
            }
            clipboard.addPrimaryClipChangedListener(() -> report(clipboard));
            Thread stdin = new Thread(() -> {
                try {
                    while (System.in.read() != -1) {
                        // Wait for the Mac side to close the pipe.
                    }
                } catch (IOException ignored) {
                    // Treat as closed
                }
                System.exit(0);
            }, "aw-clipboard-stdin");
            stdin.setDaemon(true);
            stdin.start();
            emit("AW_CLIP_READY");
            Looper.loop();
        } catch (Throwable t) {
            emit("AW_CLIP_ERROR " + encode(String.valueOf(t)));
            status = 1;
        } finally {
            System.exit(status);
        }
    }

    private static void report(ClipboardManager clipboard) {
        try {
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) {
                return;
            }
            ClipDescription description = clip.getDescription();
            String mime = "";
            if (description != null) {
                if (description.getMimeTypeCount() > 0) {
                    mime = description.getMimeType(0);
                }
                PersistableBundle extras = Build.VERSION.SDK_INT >= AndroidVersions.API_24_ANDROID_7_0 ? description.getExtras() : null;
                if (extras != null && extras.getBoolean(EXTRA_IS_SENSITIVE, false)) {
                    // Passwords and other content apps mark as sensitive never leave the phone.
                    emit("AW_CLIP_SKIPPED sensitive");
                    return;
                }
            }
            ClipData.Item item = clip.getItemAt(0);
            Uri uri = item.getUri();
            if (uri != null && "content".equals(uri.getScheme())) {
                emit("AW_CLIP_URI " + encode(mime) + " " + encode(uri.toString()));
                return;
            }
            CharSequence text = item.getText();
            if (text == null || text.length() == 0) {
                return;
            }
            if (text.length() > MAX_TEXT_CHARS) {
                emit("AW_CLIP_SKIPPED too-large");
                return;
            }
            emit("AW_CLIP_TEXT " + encode(text.toString()));
        } catch (Throwable t) {
            emit("AW_CLIP_ERROR " + encode(String.valueOf(t)));
        }
    }

    private static String encode(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    private static synchronized void emit(String line) {
        System.out.println(line);
        System.out.flush();
    }
}
