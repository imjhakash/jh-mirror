package com.johirulhoqakash.jhmirror.uicheck;
import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.util.*;

/** Tests only JH Mirror's own views and one generated image. No camera, mic or personal-file access. */
public final class PhoneUiCheck extends Instrumentation {
    private Activity activity;
    private File images;
    private final String target = "com.johirulhoqakash.jhmirror";
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    private void require(boolean value, String reason) { if (!value) throw new AssertionError(reason); }
    private List<View> children(View root) { List<View> all = new ArrayList<>(); all.add(root); if (root instanceof ViewGroup) for (int i=0; i<((ViewGroup)root).getChildCount(); i++) all.addAll(children(((ViewGroup)root).getChildAt(i))); return all; }
    private Button button(String title) {
        for (View view : children(activity.getWindow().getDecorView())) if (view instanceof Button && title.equals(((Button)view).getText().toString())) return (Button)view;
        throw new AssertionError("Missing button: " + title);
    }
    private void click(String title) { runOnMainSync(() -> button(title).performClick()); waitForIdleSync(); }
    private void screenshot(String name) {
        runOnMainSync(() -> {
            View view = activity.getWindow().getDecorView(); Bitmap bitmap = Bitmap.createBitmap(view.getWidth(), view.getHeight(), Bitmap.Config.ARGB_8888); view.draw(new Canvas(bitmap));
            try (OutputStream out = new FileOutputStream(new File(images, name + ".png"))) { require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out), "Screenshot"); } catch (IOException e) { throw new RuntimeException(e); } finally { bitmap.recycle(); }
        });
    }
    private void recreate(String theme) {
        getTargetContext().getSharedPreferences("bridge", 0).edit().putString("uiTheme", theme).commit();
        ActivityMonitor monitor = addMonitor(target + ".MainActivity", null, false);
        runOnMainSync(() -> activity.recreate());
        Activity next = monitor.waitForActivityWithTimeout(5000); removeMonitor(monitor); require(next != null, "Theme recreation"); activity = next; waitForIdleSync();
    }
    @Override public void onStart() {
        Bundle result = new Bundle(); SharedPreferences prefs = getTargetContext().getSharedPreferences("bridge", 0);
        String theme = prefs.getString("uiTheme", "system"), previousLast = prefs.getString("lastFileSent", null);
        boolean quiet = prefs.getBoolean("quietShares", true); String testName = ""; int resultCode = Activity.RESULT_CANCELED;
        try {
            images = new File(getTargetContext().getExternalFilesDir(null), "jh-ui-check-" + UUID.randomUUID()); require(images.mkdirs(), "Private UI image folder");
            activity = startActivitySync(new Intent().setClassName(target, target + ".MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); waitForIdleSync();
            click("Home");
            runOnMainSync(() -> { require(button("Send files to Mac") != null && button("Copy clipboard to Mac") != null, "Home quick actions"); }); screenshot("home");
            click("Device check");
            runOnMainSync(() -> {
                int labels = 0;
                for (View view : children(activity.getWindow().getDecorView())) if (view instanceof TextView && ((TextView)view).getText().toString().startsWith("● ")) labels++;
                require(labels == 9, "Nine independent feature signals");
            }); screenshot("device");
            click("Settings"); screenshot("settings");
            runOnMainSync(() -> {
                Switch control = null;
                for (View view : children(activity.getWindow().getDecorView())) if (view instanceof Switch && ((Switch)view).getText().toString().equals("Return to my app after sharing")) control = (Switch)view;
                require(control != null, "Quiet transfer control"); control.setChecked(!quiet); require(prefs.getBoolean("quietShares", quiet) == !quiet, "Quiet preference updates"); control.setChecked(true);
            });
            recreate("dark"); screenshot("dark"); recreate(theme);
            String id = UUID.randomUUID().toString(); Uri fixture = Uri.parse("content://com.johirulhoqakash.jhmirror.uicheck.fixture/" + id); testName = FixtureProvider.name(fixture);
            Activity share = startActivitySync(new Intent(Intent.ACTION_SEND).setClassName(target, target + ".ShareActivity").setType("image/png").putExtra(Intent.EXTRA_STREAM, fixture).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            long deadline = android.os.SystemClock.elapsedRealtime()+10000;
            while (!share.isFinishing() && !share.isDestroyed() && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(100);
            require(share.isFinishing() || share.isDestroyed(), "Successful share returns automatically without Done or a dashboard");
            deadline = android.os.SystemClock.elapsedRealtime()+20000;
            while (!testName.equals(prefs.getString("lastFileSent", "")) && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(200);
            require(testName.equals(prefs.getString("lastFileSent", "")), "Mac acknowledged and verified the generated image");
            result.putString("result", "PASS: Home, nine feature signals, quiet-transfer setting, theme recreation, automatic share closure and verified Mac delivery");
            result.putString("uiDirectory", images.getAbsolutePath()); result.putString("testFile", testName);
            resultCode = Activity.RESULT_OK;
        } catch (Throwable error) { result.putString("failure", error.toString()); if(images != null) result.putString("uiDirectory", images.getAbsolutePath()); result.putString("testFile", testName); }
        finally {
            SharedPreferences.Editor editor = prefs.edit().putString("uiTheme", theme).putBoolean("quietShares", quiet);
            if (testName.equals(prefs.getString("lastFileSent", ""))) { if (previousLast == null) editor.remove("lastFileSent"); else editor.putString("lastFileSent", previousLast); }
            editor.commit();
            if (activity != null) runOnMainSync(() -> activity.finish());
        }
        finish(resultCode, result);
    }
}
