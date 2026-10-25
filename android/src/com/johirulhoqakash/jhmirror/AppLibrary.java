package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Process;
import android.provider.Settings;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.util.List;

/** Installed-app metadata only, evaluated inside Android's fully initialized companion process. */
final class AppLibrary {
    static String snapshot(Context context, String requestedPackage) throws Exception {
        PackageManager pm=context.getPackageManager();
        ResolveInfo home=pm.resolveActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), PackageManager.MATCH_DEFAULT_ONLY);
        String homePackage=home==null || home.activityInfo==null ? "" : home.activityInfo.packageName;
        String keyboard=Settings.Secure.getString(context.getContentResolver(),Settings.Secure.DEFAULT_INPUT_METHOD);
        String keyboardPackage=keyboard==null ? "" : keyboard.split("/",2)[0];
        JSONArray apps=new JSONArray();
        if (requestedPackage!=null) {
            if (!requestedPackage.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*")) throw new IllegalArgumentException("Invalid package");
            apps.put(describe(pm,pm.getApplicationInfo(requestedPackage,0),homePackage,keyboardPackage,false));
        } else {
            List<ApplicationInfo> installed=pm.getInstalledApplications(0);
            if (installed.size()>4096) throw new IllegalStateException("Too many packages");
            int iconBytes=0;
            for (ApplicationInfo app:installed) {
                try {
                    JSONObject entry=describe(pm,app,homePackage,keyboardPackage,iconBytes<4*1024*1024);
                    iconBytes+=entry.optString("icon", "").length(); apps.put(entry);
                }
                catch (RuntimeException removedDuringRefresh) { }
            }
        }
        JSONObject result=new JSONObject();result.put("user",Process.myUid()/100000);result.put("apps",apps);
        return "JH_APPS:"+result.toString()+"\n";
    }

    private static JSONObject describe(PackageManager pm, ApplicationInfo app, String home, String keyboard, boolean includeIcon) throws Exception {
        boolean system = (app.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0;
        Intent launch = pm.getLaunchIntentForPackage(app.packageName);
        if (launch == null) launch = pm.getLeanbackLaunchIntentForPackage(app.packageName);
        String component = launch == null || launch.getComponent() == null ? "" : launch.getComponent().flattenToString();
        boolean guarded = system || app.packageName.equals("com.johirulhoqakash.jhmirror")
            || app.packageName.equals(home) || app.packageName.equals(keyboard);
        String label = String.valueOf(pm.getApplicationLabel(app));
        if (label.length() > 512) label = label.substring(0, 512);
        JSONObject entry = new JSONObject(); entry.put("package", app.packageName); entry.put("name", label);
        entry.put("system", system); entry.put("protected", guarded); entry.put("enabled", app.enabled);
        entry.put("component", component);
        if (includeIcon && app.enabled && !component.isEmpty()) {
            try {
                Drawable drawable = pm.getApplicationIcon(app);
                Bitmap bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888);
                try {
                    drawable.setBounds(0, 0, 128, 128); drawable.draw(new Canvas(bitmap));
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
                    if (bytes.size() <= 49152) entry.put("icon", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
                } finally { bitmap.recycle(); }
            } catch (RuntimeException ignored) { }
        }
        return entry;
    }
}
