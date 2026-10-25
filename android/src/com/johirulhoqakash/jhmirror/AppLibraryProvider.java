package com.johirulhoqakash.jhmirror;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import java.io.FileNotFoundException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Read-only streaming metadata. Android enforces the signature-level DUMP permission.
 * Only the companion and authorized ADB shell can read it; other phone apps cannot.
 */
public final class AppLibraryProvider extends ContentProvider {
    private final ThreadPoolExecutor worker=new ThreadPoolExecutor(1,1,30,TimeUnit.SECONDS,new ArrayBlockingQueue<>(2),r -> {
        Thread thread=new Thread(r,"jh-app-library");thread.setDaemon(true);return thread;
    });
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/json"; }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {
        if (!mode.equals("r")) throw new FileNotFoundException("Read only");
        List<String> path=uri.getPathSegments();
        final String app;
        if (path.size()==1 && path.get(0).equals("list")) app=null;
        else if (path.size()==2 && path.get(0).equals("app") && path.get(1).matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*")) app=path.get(1);
        else throw new FileNotFoundException("Unknown inventory path");
        final ParcelFileDescriptor[] pipe;
        try { pipe=ParcelFileDescriptor.createPipe(); }
        catch (java.io.IOException error) { throw new FileNotFoundException("Could not open inventory"); }
        try {
            worker.execute(() -> {
                try (OutputStream output=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    String snapshot=AppLibrary.snapshot(getContext(),app);
                    byte[] bytes=snapshot.getBytes(StandardCharsets.UTF_8);
                    if (bytes.length>24*1024*1024) throw new IllegalStateException("Inventory too large");
                    output.write(bytes);
                } catch (Exception error) {
                    android.util.Log.w("JHMirror","App inventory unavailable: "+error.getClass().getSimpleName());
                }
            });
            return pipe[0];
        } catch (RuntimeException busy) {
            try { pipe[0].close();pipe[1].close(); } catch (java.io.IOException ignored) { }
            throw new FileNotFoundException("Inventory busy");
        }
    }
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort) { throw new UnsupportedOperationException("Use read"); }
    @Override public Uri insert(Uri uri,ContentValues values) { throw new UnsupportedOperationException("Read only"); }
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args) { throw new UnsupportedOperationException("Read only"); }
    @Override public int delete(Uri uri,String selection,String[] args) { throw new UnsupportedOperationException("Read only"); }
}
