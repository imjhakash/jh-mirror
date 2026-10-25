package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.Base64;
import android.util.LruCache;
import java.io.ByteArrayOutputStream;

final class AppIcons {
    private static final LruCache<String, String> cache = new LruCache<>(64);
    static String get(Context context, String app) {
        String cached = cache.get(app);
        if (cached != null) return cached;
        try {
            Drawable drawable = context.getPackageManager().getApplicationIcon(app);
            Bitmap bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, 64, 64); drawable.draw(canvas);
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
            bitmap.recycle();
            String encoded = Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP);
            cache.put(app, encoded); return encoded;
        } catch (Exception ignored) { return ""; }
    }
}
