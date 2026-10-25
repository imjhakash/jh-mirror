package com.genymobile.scrcpy;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.media.MediaMetadataRetriever;
import android.content.ContentResolver;
import android.content.Context;
import android.content.IContentProvider;
import android.database.Cursor;
import android.os.Binder;
import android.provider.MediaStore;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.channels.FileLock;
import java.security.MessageDigest;
import java.util.*;

/** One-shot commands under the already-authorized ADB shell. No socket, root or app-data access. */
public final class JHFiles {
    private final File root;
    private final int user;
    private JHFiles(int user) throws Exception {
        if (user < 0 || user > 10000) throw new IOException("Invalid phone user");
        this.user=user;
        root = new File("/storage/emulated/" + user).getCanonicalFile();
        if (!root.isDirectory() || !root.canRead()) throw new IOException("Phone shared storage is unavailable");
    }
    private static String decode(String value) { return value.equals("-") ? "" : new String(Base64.decode(value, Base64.NO_WRAP), StandardCharsets.UTF_8); }
    private File file(String path) throws Exception {
        if (path.startsWith("/") || path.indexOf('\0') >= 0) throw new IOException("Invalid path");
        for (String part : path.split("/")) if (part.equals("..") || part.equals(".")) throw new IOException("Invalid path");
        File value = new File(root, path).getCanonicalFile();
        String relative = relative(value);
        if (relative.equals("Android/data") || relative.startsWith("Android/data/") || relative.equals("Android/obb") || relative.startsWith("Android/obb/"))
            throw new IOException("Android protects this app storage");
        return value;
    }
    private String relative(File value) throws IOException {
        String path=value.getPath(), base=root.getPath();
        if (path.equals(base)) return "";
        if (!path.startsWith(base + "/")) throw new IOException("Path leaves shared storage");
        return path.substring(base.length()+1);
    }
    private static String name(String raw) throws IOException {
        if (raw.isEmpty() || raw.equals(".") || raw.equals("..") || raw.contains("/") || raw.indexOf('\0')>=0 || raw.getBytes(StandardCharsets.UTF_8).length>240)
            throw new IOException("Invalid file name");
        return raw;
    }
    private static String kind(File value) {
        if (value.isDirectory()) return "folder";
        return kindName(value.getName());
    }
    private static String kindName(String name) {
        String n=name.toLowerCase(Locale.ROOT);
        if (n.matches(".*\\.(jpg|jpeg|png|webp|heic|heif|gif|bmp|avif|dng)$")) return "photo";
        if (n.matches(".*\\.(mp4|m4v|mov|mkv|webm|3gp|avi|ts)$")) return "video";
        if (n.matches(".*\\.(mp3|m4a|aac|wav|flac|ogg|opus|amr)$")) return "audio";
        return "file";
    }
    private JSONObject info(File f) throws Exception {
        if (!f.exists()) throw new IOException("File no longer exists");
        return new JSONObject().put("path",relative(f)).put("name",f.getName()).put("directory",f.isDirectory())
            .put("size",f.isDirectory()?0:f.length()).put("modified",f.lastModified()).put("kind",kind(f));
    }
    private File[] children(File folder) throws Exception {
        if (!folder.isDirectory()) throw new IOException("Not a folder");
        File[] children=folder.listFiles();
        if (children==null) throw new IOException("Android does not allow reading this folder");
        Arrays.sort(children, new Comparator<File>() { @Override public int compare(File a, File b) { return String.CASE_INSENSITIVE_ORDER.compare(a.getName(),b.getName()); } });
        return children;
    }
    private boolean visible(File f) {
        return !f.getName().startsWith(".") && !f.getName().startsWith(".jhmirror-");
    }
    private JSONObject list(File folder) throws Exception {
        JSONArray result=new JSONArray(); boolean more=false;
        for (File child:children(folder)) {
            if (!visible(child)) continue;
            try { child=file(relative(child)); } catch(Exception denied) { continue; }
            if (result.length()>=20000) { more=true;break; }
            try { result.put(info(child)); } catch(Exception disappeared) { /* Files can disappear while a folder is being read. */ }
        }
        return new JSONObject().put("path",relative(folder)).put("items",result).put("truncated",more);
    }
    private void walk(File directory, List<File> result, Set<String> seen, int depth, String media) throws Exception {
        if (depth>40 || seen.size()>100000 || result.size()>=20000 || !seen.add(directory.getCanonicalPath())) return;
        if (media!=null && new File(directory,".nomedia").exists()) return;
        File[] values;
        try { values=children(directory); } catch (Exception denied) { return; }
        for (File child:values) {
            if (child.getName().startsWith(".jhmirror-") || (media!=null && !visible(child))) continue;
            try { child=file(relative(child)); } catch (Exception denied) { continue; }
            if (child.isDirectory()) {
                if (media==null) result.add(child);
                walk(child,result,seen,depth+1,media);
            } else if (media==null || kind(child).equals(media)) result.add(child);
            if (result.size()>=20000) return;
        }
    }
    private JSONObject tree(File directory, String media) throws Exception {
        List<File> values=new ArrayList<>(); walk(directory,values,new HashSet<>(),0,media);
        // The Mac sorts the returned metadata; avoid repeated FUSE stats inside a comparator.
        JSONArray result=new JSONArray();for (File f:values) { try { result.put(info(f)); } catch(Exception disappeared) { /* Keep the readable entries. */ } }
        return new JSONObject().put("path",relative(directory)).put("items",result).put("truncated",values.size()>=20000);
    }
    private JSONObject media(String kind) throws Exception { return media(kind,20000,true); }
    private JSONObject media(String kind,int limit,boolean fallback) throws Exception {
        // The existing provider wrapper addresses Android user 0 only. Other users safely use their own storage walk.
        if(user!=0)return fallback?tree(root,kind):new JSONObject().put("path", "").put("items", new JSONArray()).put("truncated", true);
        try {
            if(android.os.Looper.getMainLooper()==null)android.os.Looper.prepareMainLooper();
            Workarounds.apply();
            final Binder token=new Binder();
            final IContentProvider provider=ServiceManager.getActivityManager().getContentProviderExternal("media",token);
            if(provider==null)throw new IOException("Media index unavailable");
            ContentResolver resolver=new ContentResolver(FakeContext.get()) {
                @SuppressWarnings("unused") protected IContentProvider acquireProvider(Context c,String name){return name.equals("media")?provider:null;}
                @SuppressWarnings("unused") protected IContentProvider acquireUnstableProvider(Context c,String name){return name.equals("media")?provider:null;}
                @SuppressWarnings("unused") public boolean releaseProvider(IContentProvider p){return true;}
                @SuppressWarnings("unused") public boolean releaseUnstableProvider(IContentProvider p){return true;}
                @SuppressWarnings("unused") public void unstableProviderDied(IContentProvider p){}
            };
            int type=kind.equals("photo")?1:kind.equals("video")?3:2;
            JSONArray result=new JSONArray();Set<String> seen=new HashSet<>();boolean more=false;
            String selection = JHMediaQuery.selection(android.os.Build.VERSION.SDK_INT);
            try(Cursor cursor=resolver.query(MediaStore.Files.getContentUri("external"),new String[]{"_data","_size","date_modified"},
                    selection,new String[]{String.valueOf(type)},"date_modified DESC, _id DESC")) {
                if(cursor==null)throw new IOException("Media index unavailable");
                while(cursor.moveToNext()) {
                    String raw=cursor.getString(0);if(raw==null)continue;
                    try {
                        // Index rows are display snapshots. Exact canonical paths/size/mtime are resolved before preview, copy or delete.
                        String base=root.getPath()+"/";if(!raw.startsWith(base))continue;
                        String path=raw.substring(base.length());boolean hidden=false;
                        for(String part:path.split("/"))if(part.startsWith(".") || part.isEmpty()) {hidden=true;break;}
                        if(hidden || path.equals("Android/data") || path.startsWith("Android/data/") || path.equals("Android/obb") || path.startsWith("Android/obb/"))continue;
                        File f=new File(raw);long size=cursor.getLong(1),seconds=cursor.getLong(2);
                        if(size<0 || seconds<0 || seconds>253402300799L || !kindName(f.getName()).equals(kind) || !seen.add(path))continue;
                        if(result.length()>=limit){more=true;break;}
                        result.put(new JSONObject().put("path",path).put("name",f.getName()).put("directory",false)
                            .put("size",size).put("modified",seconds*1000).put("kind",kind).put("indexed",true));
                    } catch(Exception unavailable) { /* Removed/unreadable/private rows do not fail the whole gallery. */ }
                }
            }
            return new JSONObject().put("path","").put("items",result).put("truncated",more).put("indexed",true);
        } catch(Exception unavailable) {
            return fallback?tree(root,kind):new JSONObject().put("path", "").put("items", new JSONArray()).put("truncated", true);
        }
    }
    private static String hash(File f) throws Exception {
        MessageDigest hash=MessageDigest.getInstance("SHA-256");byte[] bytes=new byte[1024*1024];
        try (InputStream input=new FileInputStream(f)) { int n;while ((n=input.read(bytes))!=-1) hash.update(bytes,0,n); }
        StringBuilder text=new StringBuilder();for (byte b:hash.digest()) text.append(String.format(Locale.ROOT,"%02x",b&255));return text.toString();
    }
    private static void checkSource(File f,long size,long modified) throws Exception {
        if (!f.isFile() || f.length()!=size || f.lastModified()!=modified) throw new IOException("Source changed. Refresh and try again.");
    }
    private JSONObject removePhoto(File f,long size,long modified) throws Exception {
        String path=relative(f);
        if(path.isEmpty() || !kind(f).equals("photo"))throw new IOException("Only selected photos can be deleted here");
        checkSource(f,size,modified);
        if(!f.delete())throw new IOException("Android could not delete this photo");
        return new JSONObject().put("deleted",path);
    }
    private void read(File f,long offset,long size,long modified) throws Exception {
        checkSource(f,size,modified);if (offset<0 || offset>size) throw new IOException("Invalid resume offset");
        try (RandomAccessFile input=new RandomAccessFile(f,"r")) {
            input.seek(offset);byte[] buffer=new byte[256*1024];long left=size-offset;
            while (left>0) { int n=input.read(buffer,0,(int)Math.min(left,buffer.length));if(n<0)throw new EOFException();System.out.write(buffer,0,n);left-=n; }
            System.out.flush();
        }
        checkSource(f,size,modified);
    }
    private File uploadFile(File parent,String token,String suffix) throws Exception {
        if (!token.matches("[0-9a-f]{32}")) throw new IOException("Invalid transfer ID");
        if (!parent.isDirectory()) throw new IOException("Destination folder is unavailable");
        return file(relative(parent)+ (relative(parent).isEmpty()?"":"/") +".jhmirror-"+token+suffix);
    }
    private File lockFile(String token) throws Exception {
        if (!token.matches("[0-9a-f]{32}")) throw new IOException("Invalid transfer ID");
        File directory=new File("/data/local/tmp/jh-file-locks");
        if(!directory.isDirectory()&&!directory.mkdir())throw new IOException("Transfer lock unavailable");
        android.system.Os.chmod(directory.getPath(),0700);
        return new File(directory,root.getName()+"-"+token);
    }
    private Properties metadata(File parent,String token) throws Exception {
        Properties data=new Properties();try (InputStream in=new FileInputStream(uploadFile(parent,token,".json"))) { data.load(in); }return data;
    }
    private void saveMetadata(File parent,String token,Properties data) throws Exception {
        File target=uploadFile(parent,token,".json"),temp=uploadFile(parent,token,".meta-tmp");
        try (FileOutputStream out=new FileOutputStream(temp)) { data.store(out,"JH Mirror resumable transfer");out.getFD().sync(); }
        if (!temp.renameTo(target)) throw new IOException("Could not save transfer state");
    }
    private JSONObject begin(File parent,String token,String rawName,long size,String sha) throws Exception {
        String n=name(rawName);if(size<0 || !sha.matches("[0-9a-f]{64}"))throw new IOException("Invalid transfer metadata");
        File meta=uploadFile(parent,token,".json"),part=uploadFile(parent,token,".partial");
        Properties data;
        if (meta.exists()) {
            data=metadata(parent,token);
            if (!n.equals(data.getProperty("name")) || !Long.toString(size).equals(data.getProperty("size")) || !sha.equals(data.getProperty("sha")))
                throw new IOException("Source changed since transfer was paused");
        } else {
            if (part.exists()) throw new IOException("Unrecognized partial file");
            data=new Properties();data.setProperty("name",n);data.setProperty("size",Long.toString(size));data.setProperty("sha",sha);saveMetadata(parent,token,data);
        }
        String target=data.getProperty("target");
        if (target!=null && !part.exists()) {
            File done=file(target);
            if(done.isFile() && done.length()==size && hash(done).equals(sha))return new JSONObject().put("offset",size).put("completed",info(done));
        }
        if (!part.exists() && !part.createNewFile()) throw new IOException("Could not create partial file");
        if (!part.isFile() || part.length()>size) throw new IOException("Invalid partial file");
        // An interrupted old shell can still be draining buffered bytes. Wait for its writer before reporting the resume offset.
        try(RandomAccessFile lock=new RandomAccessFile(lockFile(token),"rw");FileLock held=lock.getChannel().lock()) {
            long remaining=size-part.length(),free=parent.getUsableSpace();
            if(remaining>0 && (free<32L*1024*1024 || remaining>free-32L*1024*1024))throw new IOException("Not enough free space on phone. Free some space, then Resume.");
            return new JSONObject().put("offset",part.length());
        }
    }
    private JSONObject write(File parent,String token,long offset) throws Exception {
        Properties data=metadata(parent,token);long size=Long.parseLong(data.getProperty("size"));File part=uploadFile(parent,token,".partial");
        try(RandomAccessFile lock=new RandomAccessFile(lockFile(token),"rw");FileLock held=lock.getChannel().lock();RandomAccessFile out=new RandomAccessFile(part,"rw")) {
            if (!part.isFile() || part.length()!=offset || offset<0 || offset>size) throw new IOException("Resume offset changed");
            out.seek(offset);byte[] buffer=new byte[256*1024];long left=size-offset;
            try { while(left>0) {
                if(System.in.available()==0) {
                    android.system.StructPollfd fd=new android.system.StructPollfd();fd.fd=FileDescriptor.in;fd.events=(short)android.system.OsConstants.POLLIN;
                    if(android.system.Os.poll(new android.system.StructPollfd[]{fd},45000)==0)throw new IOException("Upload paused after no incoming data");
                }
                int n=System.in.read(buffer,0,(int)Math.min(left,buffer.length));if(n<0)throw new EOFException("Transfer interrupted");out.write(buffer,0,n);left-=n;
            } }
            finally { out.getFD().sync(); }
        }
        return new JSONObject().put("offset",part.length());
    }
    private JSONObject commit(File parent,String token) throws Exception {
        Properties data=metadata(parent,token);File part=uploadFile(parent,token,".partial");long size=Long.parseLong(data.getProperty("size"));String sha=data.getProperty("sha");
        String reserved=data.getProperty("target");
        if (!part.exists() && reserved!=null) {
            File done=file(reserved);if(done.isFile()&&done.length()==size&&hash(done).equals(sha)) return info(done);
        }
        if (!part.isFile() || part.length()!=size || !hash(part).equals(sha)) throw new IOException("File verification failed; source and partial copy were kept");
        File target=null;
        // FUSE shared storage does not support hard links. Reserve a fresh name atomically before replacing our own empty reservation.
        if (reserved!=null) {
            File candidate=file(reserved);
            if(candidate.isFile()&&candidate.length()==0&&Long.toString(candidate.lastModified()).equals(data.getProperty("reservedAt")))target=candidate;
        }
        String original=data.getProperty("name");int dot=original.lastIndexOf('.');String stem=dot>0?original.substring(0,dot):original,ext=dot>0?original.substring(dot):"";
        for (int n=1;target==null&&n<=10000;n++) {
            File candidate=file(relative(parent)+(relative(parent).isEmpty()?"":"/")+(n==1?original:stem+" ("+n+")"+ext));
            if(candidate.createNewFile())target=candidate;
        }
        if(target==null)throw new IOException("Could not choose a free destination name");
        data.setProperty("target",relative(target));data.setProperty("reservedAt",Long.toString(target.lastModified()));saveMetadata(parent,token,data);
        if(target.length()!=0||!Long.toString(target.lastModified()).equals(data.getProperty("reservedAt"))||!part.renameTo(target))throw new IOException("Destination changed; retry the transfer");
        // MediaProvider/FUSE stores modification timestamps in seconds. Normalize before returning metadata.
        target.setLastModified((System.currentTimeMillis()/1000L)*1000L);
        return info(target);
    }
    private static boolean previewContextReady;
    private static void preparePreviewContext() {
        if(previewContextReady)return;
        if(android.os.Looper.getMainLooper()==null)android.os.Looper.prepareMainLooper();
        Workarounds.apply();previewContextReady=true;
    }
    private void verifyPreviewPeer(String identity) throws Exception {
        String serial=(String)Class.forName("android.os.SystemProperties").getMethod("get",String.class).invoke(null,"ro.serialno");
        if(identity.isEmpty() || !identity.equals(serial))throw new IOException("The connected phone changed");
        Object manager=Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        int current;
        try { current=(Integer)manager.getClass().getMethod("getCurrentUserId").invoke(manager); }
        catch(NoSuchMethodException old) { Object info=manager.getClass().getMethod("getCurrentUser").invoke(manager);current=info.getClass().getField("id").getInt(info); }
        if(current!=user)throw new IOException("Phone user changed. Refresh the gallery");
    }
    private JSONObject preview(File f,long size,long modified,boolean indexed,String identity) throws Exception {
        preparePreviewContext();
        verifyPreviewPeer(identity);
        if(!f.isFile() || f.length()!=size || (indexed?f.lastModified()/1000!=modified/1000:f.lastModified()!=modified))
            throw new IOException("Photo changed. Refresh and try again");
        long exact=f.lastModified();JSONObject metadata=info(f),result=render(f,1600,85);
        checkSource(f,size,exact);
        return result.put("file",metadata);
    }
    private void thumbnails(String identity,String requests) throws Exception {
        JSONArray files=new JSONArray(requests);
        if(files.length()<1||files.length()>6)throw new IOException("Invalid thumbnail batch");
        preparePreviewContext();
        for(int i=0;i<files.length();i++) {
            JSONObject result=new JSONObject().put("index",i);
            try {
                verifyPreviewPeer(identity);
                JSONObject entry=files.getJSONObject(i);File f=file(entry.getString("path"));
                long size=entry.getLong("size"),modified=entry.getLong("modified");boolean indexed=entry.optBoolean("indexed",false);
                if(!f.isFile()||f.length()!=size||(indexed?f.lastModified()/1000!=modified/1000:f.lastModified()!=modified))throw new IOException("Photo changed");
                long exact=f.lastModified();result=render(f,256,70).put("index",i);checkSource(f,size,exact);
            } catch(Exception unavailable) { result=new JSONObject().put("index",i).put("error","Thumbnail unavailable"); }
            System.out.println(result.toString());System.out.flush();
        }
    }
    private JSONObject render(File f,int edge,int quality) throws Exception {
        preparePreviewContext();
        Bitmap bitmap=null;
        try {
            if(kind(f).equals("photo")) {
                BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(f.getPath(),bounds);
                if(bounds.outWidth<1||bounds.outHeight<1)throw new IOException("No image preview");
                BitmapFactory.Options options=new BitmapFactory.Options();int sample=1;
                while(Math.max(bounds.outWidth,bounds.outHeight)/(sample*2)>=edge)sample*=2;
                options.inSampleSize=sample;bitmap=BitmapFactory.decodeFile(f.getPath(),options);
                if(bitmap!=null) {
                    Matrix matrix=new Matrix();
                    try {
                        int orientation=new ExifInterface(f.getPath()).getAttributeInt(ExifInterface.TAG_ORIENTATION,1);
                        switch(orientation) {
                            case 2:matrix.setScale(-1,1);break;
                            case 3:matrix.setRotate(180);break;
                            case 4:matrix.setScale(1,-1);break;
                            case 5:matrix.setRotate(90);matrix.postScale(-1,1);break;
                            case 6:matrix.setRotate(90);break;
                            case 7:matrix.setRotate(-90);matrix.postScale(-1,1);break;
                            case 8:matrix.setRotate(270);break;
                            default:break;
                        }
                    } catch(IOException unsupported) { /* Image can still be previewed without EXIF. */ }
                    if(!matrix.isIdentity()) { Bitmap oriented=Bitmap.createBitmap(bitmap,0,0,bitmap.getWidth(),bitmap.getHeight(),matrix,true);if(oriented!=bitmap){bitmap.recycle();bitmap=oriented;} }
                }
            } else if(kind(f).equals("video")) {
                MediaMetadataRetriever retriever=new MediaMetadataRetriever();try {
                    retriever.setDataSource(f.getPath());
                    bitmap=android.os.Build.VERSION.SDK_INT>=27 ? retriever.getScaledFrameAtTime(0,MediaMetadataRetriever.OPTION_CLOSEST_SYNC,edge,edge)
                        : retriever.getFrameAtTime(0,MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
                } finally { retriever.release(); }
            }
            if(bitmap==null)throw new IOException("No preview");
            if(Math.max(bitmap.getWidth(),bitmap.getHeight())>edge) {
                double scale=(double)edge/Math.max(bitmap.getWidth(),bitmap.getHeight());
                Bitmap small=Bitmap.createScaledBitmap(bitmap,Math.max(1,(int)(bitmap.getWidth()*scale)),Math.max(1,(int)(bitmap.getHeight()*scale)),true);
                if(small!=bitmap){bitmap.recycle();bitmap=small;}
            }
            ByteArrayOutputStream out=new ByteArrayOutputStream();bitmap.compress(bitmap.hasAlpha()?Bitmap.CompressFormat.PNG:Bitmap.CompressFormat.JPEG,quality,out);
            int limit=edge<=384?256*1024:3*1024*1024;
            while(out.size()>limit && Math.max(bitmap.getWidth(),bitmap.getHeight())>256) {
                Bitmap small=Bitmap.createScaledBitmap(bitmap,Math.max(1,bitmap.getWidth()/2),Math.max(1,bitmap.getHeight()/2),true);bitmap.recycle();bitmap=small;
                out.reset();bitmap.compress(bitmap.hasAlpha()?Bitmap.CompressFormat.PNG:Bitmap.CompressFormat.JPEG,quality,out);
            }
            if(out.size()>limit)throw new IOException("Preview too large");
            return new JSONObject().put("image",Base64.encodeToString(out.toByteArray(),Base64.NO_WRAP));
        } finally { if(bitmap!=null)bitmap.recycle(); }
    }
    public static void main(String[] args) {
        try {
            if(args.length<3)throw new IOException("Missing command");
            JHFiles service=new JHFiles(Integer.parseInt(args[1]));String operation=args[0];File f=service.file(decode(args[2]));JSONObject result;
            switch(operation) {
                case "list":result=service.list(f);break;
                case "info":result=service.info(f);break;
                case "tree":result=service.tree(f,null);break;
                case "photo":case "video":case "audio":result=f.equals(service.root)?service.media(operation):service.tree(f,operation);break;
                case "photo-first":case "video-first":case "audio-first":result=service.media(operation.substring(0,operation.indexOf('-')),120,false);break;
                case "thumb-batch":service.thumbnails(decode(args[3]),decode(args[4]));return;
                case "hash":checkSource(f,Long.parseLong(args[3]),Long.parseLong(args[4]));result=new JSONObject().put("sha256",hash(f));break;
                case "read":service.read(f,Long.parseLong(args[3]),Long.parseLong(args[4]),Long.parseLong(args[5]));return;
                case "begin":result=service.begin(f,args[3],decode(args[4]),Long.parseLong(args[5]),args[6]);break;
                case "write":result=service.write(f,args[3],Long.parseLong(args[4]));break;
                case "commit":result=service.commit(f,args[3]);break;
                case "finish":service.uploadFile(f,args[3],".json").delete();service.lockFile(args[3]).delete();result=new JSONObject().put("ok",true);break;
                case "mkdir":if(!f.isDirectory()&&!f.mkdirs())throw new IOException("Could not create folder");result=service.info(f);break;
                case "newdir":
                    String n=name(decode(args[3]));File dir=null;
                    for(int i=1;i<=10000;i++) { File candidate=service.file(service.relative(f)+(service.relative(f).isEmpty()?"":"/")+n+(i==1?"":" ("+i+")"));if(candidate.mkdir()){dir=candidate;break;} }
                    if(dir==null)throw new IOException("Could not create folder");result=service.info(dir);break;
                case "thumb":result=service.render(f,384,75);break;
                case "preview":result=service.preview(f,Long.parseLong(args[3]),Long.parseLong(args[4]),args[5].equals("1"),decode(args[6]));break;
                case "delete-photo":result=service.removePhoto(f,Long.parseLong(args[3]),Long.parseLong(args[4]));break;
                default:throw new IOException("Unknown command");
            }
            System.out.println(result.toString());
        } catch(Throwable error) {
            try { System.err.println(new JSONObject().put("error",error.getMessage()==null?error.getClass().getSimpleName():error.getMessage())); } catch(Exception ignored) { }
            System.exit(1);
        }
    }
}
