package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** Only files explicitly shared/picked by the user enter this private, persistent queue. */
final class FileOutbox {
    static final long MAX_FILE = 2L * 1024 * 1024 * 1024;
    interface Progress { void update(String message); }
    private static File directory(Context c) {
        File dir = new File(c.getFilesDir(), "outbox"); dir.mkdirs(); return dir;
    }
    static void cleanupInterruptedPreparation(Context c) {
        File[] files = directory(c).listFiles();
        if (files == null) return;
        long old = System.currentTimeMillis() - 86400000L;
        for (File file : files) {
            String name = file.getName();
            if (file.lastModified() >= old) continue;
            if (name.endsWith(".partial") || name.endsWith(".json.tmp")) file.delete();
            else if (name.endsWith(".data") && !new File(file.getParentFile(), name.replace(".data", ".json")).exists())
                file.delete();
        }
    }
    static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte b : bytes) result.append(String.format(Locale.US, "%02x", b & 255));
        return result.toString();
    }
    static String safeName(String name) {
        if (name == null) name = "Shared file";
        name = name.replaceAll("[/\\\\\\p{Cntrl}]", "_").trim();
        if (name.isEmpty() || name.equals(".") || name.equals("..")) name = "Shared file";
        return name.length() > 180 ? name.substring(0, 180) : name;
    }
    /** Files queued with this purpose are placed on the Mac clipboard after they arrive. */
    static final String CLIPBOARD = "clipboard";
    static final int MAX_QUEUE = 100;
    /** Items still being prepared. Counted with the queue so concurrent shares cannot exceed it. */
    private static int preparing;

    private static void reserve(Context c) throws IOException {
        synchronized (FileOutbox.class) {
            if (list(c).length() + preparing >= MAX_QUEUE)
                throw new IOException("Queue is full. Connect your Mac to finish pending files.");
            preparing++;
        }
    }
    private static void unreserve() { synchronized (FileOutbox.class) { preparing--; } }

    static void stage(Context c, Uri uri, Progress progress) throws Exception { stage(c, uri, null, progress); }

    static void stage(Context c, Uri uri, String purpose, Progress progress) throws Exception {
        if (uri == null || !"content".equals(uri.getScheme()))
            throw new IOException("Select a file using the Share menu or file picker.");
        String name = "Shared file"; long size = -1;
        try (Cursor cursor = c.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                int s = cursor.getColumnIndex(OpenableColumns.SIZE);
                if (n >= 0) name = cursor.getString(n);
                if (s >= 0 && !cursor.isNull(s)) size = cursor.getLong(s);
            }
        }
        name = safeName(name);
        if (size > MAX_FILE) throw new IOException("Maximum file size is 2 GB.");
        File dir = directory(c);
        if (size >= 0 && dir.getUsableSpace() < size + 32 * 1024 * 1024)
            throw new IOException("Not enough free space to prepare this file.");
        String mime = c.getContentResolver().getType(uri);
        reserve(c);
        try (InputStream in = c.getContentResolver().openInputStream(uri)) {
            if (in == null) throw new IOException("The source app did not provide a readable file.");
            write(c, in, name, mime, purpose, progress);
        } finally { unreserve(); }
    }

    /** Queues copied text. It reaches the Mac clipboard as plain text. */
    static void stageText(Context c, CharSequence text, Progress progress) throws Exception {
        byte[] bytes = text.toString().getBytes("UTF-8");
        if (bytes.length > 8 * 1024 * 1024) throw new IOException("Copied text is too large.");
        String stamp = new java.text.SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(new Date());
        reserve(c);
        try { write(c, new ByteArrayInputStream(bytes), "Phone clipboard " + stamp + ".txt", "text/plain", CLIPBOARD, progress); }
        finally { unreserve(); }
    }

    private static void write(Context c, InputStream in, String name, String mime, String purpose, Progress progress) throws Exception {
        File dir = directory(c);
        String id = UUID.randomUUID().toString();
        File partial = new File(dir, id + ".partial");
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        long total = 0; long lastProgress = 0;
        try {
            try (FileOutputStream out = new FileOutputStream(partial)) {
                byte[] buffer = new byte[65536]; int count;
                while ((count = in.read(buffer)) != -1) {
                    total += count;
                    if (total > MAX_FILE) throw new IOException("Maximum file size is 2 GB.");
                    out.write(buffer, 0, count); hash.update(buffer, 0, count);
                    if (total - lastProgress >= 1024 * 1024) {
                        lastProgress = total;
                        progress.update("Preparing " + name + " · " + total / 1048576 + " MB");
                    }
                }
                out.getFD().sync();
            }
            File data = new File(dir, id + ".data");
            if (!partial.renameTo(data)) throw new IOException("Could not prepare file.");
            JSONObject item = new JSONObject();
            item.put("id", id); item.put("name", name); item.put("size", total);
            item.put("sha256", hex(hash.digest())); item.put("created", System.currentTimeMillis());
            item.put("mime", mime == null ? "application/octet-stream" : mime);
            if (purpose != null) item.put("purpose", purpose);
            File metadata = new File(dir, id + ".json.tmp");
            try (FileOutputStream out = new FileOutputStream(metadata)) {
                out.write(item.toString().getBytes("UTF-8")); out.getFD().sync();
            }
            if (!metadata.renameTo(new File(dir, id + ".json"))) throw new IOException("Could not queue file.");
            progress.update(CLIPBOARD.equals(purpose)
                ? "Copied to your Mac clipboard: " + name + "\nPress ⌘V on the Mac to paste."
                : "Queued: " + name + "\nYour Mac receives it automatically when connected. Original file stays on the phone.");
        } catch (Exception e) {
            partial.delete(); new File(dir, id + ".data").delete(); new File(dir, id + ".json.tmp").delete();
            throw e;
        }
    }
    static synchronized JSONArray list(Context c) {
        JSONArray items = new JSONArray(); File[] files = directory(c).listFiles();
        if (files == null) return items;
        Arrays.sort(files, Comparator.comparingLong(File::lastModified));
        for (File file : files) if (file.getName().endsWith(".json")) {
            try {
                if (file.length() > 8192) continue;
                byte[] bytes = new byte[(int)file.length()];
                try (DataInputStream in = new DataInputStream(new FileInputStream(file))) { in.readFully(bytes); }
                JSONObject item = new JSONObject(new String(bytes, "UTF-8"));
                if (new File(directory(c), item.getString("id") + ".data").isFile()) items.put(item);
            } catch (Exception ignored) { }
        }
        return items;
    }
    static File data(Context c, String id) throws IOException {
        if (!id.matches("[0-9a-f-]{36}")) throw new IOException("Invalid file");
        if (!new File(directory(c), id + ".json").isFile()) throw new FileNotFoundException();
        File data = new File(directory(c), id + ".data");
        if (!data.isFile()) throw new FileNotFoundException();
        return data;
    }
    static synchronized boolean acknowledge(Context c, String id, String hash) {
        JSONArray items = list(c);
        for (int i = 0; i < items.length(); i++) {
            JSONObject item = items.optJSONObject(i);
            if (id.equals(item.optString("id")) && hash.equals(item.optString("sha256"))) {
                // Delete only this app's staging copy after the Mac verifies and saves the file.
                File metadata = new File(directory(c), id + ".json");
                if (!metadata.delete()) return false;
                new File(directory(c), id + ".data").delete();
                c.getSharedPreferences("bridge", 0).edit().putString("lastFileSent", item.optString("name")).apply();
                return true;
            }
        }
        return true; // Idempotent: the Mac may retry an ACK after losing its response.
    }
}
