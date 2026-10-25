package com.johirulhoqakash.jhmirror.uicheck;
import android.content.*;
import android.database.*;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.*;

public final class FixtureProvider extends ContentProvider {
    static final byte[] PNG = android.util.Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aMCsAAAAASUVORK5CYII=", 0);
    static String name(Uri uri) {
        String id = uri.getLastPathSegment();
        if (uri.getPathSegments().size() != 1 || id == null || !id.matches("[0-9a-f-]{36}")) throw new IllegalArgumentException("Fixture only");
        return "JH UI Quiet Share Check " + id + ".png";
    }
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { name(uri); return "image/png"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        String name = name(uri); String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns); Object[] row = new Object[columns.length];
        for (int i = 0; i < row.length; i++) row[i] = OpenableColumns.DISPLAY_NAME.equals(columns[i]) ? name : PNG.length;
        cursor.addRow(row); return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        name(uri); if (!"r".equals(mode)) throw new FileNotFoundException("Read-only fixture");
        try { ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            new Thread(() -> { try (OutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) { out.write(PNG); } catch (IOException ignored) { } }).start(); return pipe[0];
        } catch (IOException e) { throw new FileNotFoundException(e.toString()); }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
