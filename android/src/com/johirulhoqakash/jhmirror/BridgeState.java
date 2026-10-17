package local.androidwireless.bridge;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.SSLSocket;

final class BridgeState {
    static final int PORT = 38475;
    static final int PROTOCOL = 5;
    static final String SESSION = UUID.randomUUID().toString();
    static volatile boolean listenerConnected;
    private static long sequence;
    private static final ArrayDeque<JSONObject> events = new ArrayDeque<>();
    private static ServerSocket server;
    private static Context context;
    // The ADB loopback and the LAN listener use separate pools, so unauthenticated
    // LAN clients can never starve the ADB fallback (or each other for long).
    private static final ThreadPoolExecutor loopbackClients = pool("wireless-loopback-client", 2, 8);
    private static final ThreadPoolExecutor lanClients = pool("wireless-lan-client", 4, 4);
    private static final ScheduledExecutorService deadlines = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "wireless-deadline"); t.setDaemon(true); return t;
    });
    private static final Map<InetAddress, Integer> lanPerAddress = new HashMap<>();
    private static final int MAX_LAN_PER_ADDRESS = 3;
    /** Unauthenticated clients must finish TLS + request headers within this time. */
    private static final long HEADER_DEADLINE_MS = 6000;

    private static ThreadPoolExecutor pool(String name, int threads, int queue) {
        return new ThreadPoolExecutor(threads, threads, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<>(queue), r -> {
            Thread t = new Thread(r, name); t.setDaemon(true); return t;
        });
    }

    /** Returns true only when the loopback listener is running. */
    static synchronized boolean start(Context app) {
        context = app.getApplicationContext();
        if (server != null && !server.isClosed()) return true;
        FileOutbox.cleanupInterruptedPreparation(context);
        for (int attempt = 0; attempt < 3; attempt++) {
            ServerSocket listener = null;
            try {
                listener = new ServerSocket();
                listener.setReuseAddress(true);
                listener.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT), 8);
                final ServerSocket accepted = listener;
                server = listener;
                Thread accept = new Thread(() -> {
                    while (!accepted.isClosed()) {
                        try { accept(accepted.accept(), false); }
                        catch (IOException e) { break; }
                    }
                    synchronized (BridgeState.class) { if (server == accepted) server = null; }
                }, "wireless-loopback");
                accept.setDaemon(true); accept.start();
                return true;
            } catch (IOException e) {
                android.util.Log.w("AndroidWireless", "Loopback listener bind failed", e);
                if (listener != null) try { listener.close(); } catch (IOException ignored) { }
                server = null;
                try { Thread.sleep(250); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); break; }
            }
        }
        return false;
    }

    static void accept(Socket socket, boolean lan) {
        try {
            socket.setSoTimeout(5000); socket.setTcpNoDelay(true); socket.setKeepAlive(true);
        } catch (IOException e) { closeQuietly(socket); return; }
        final InetAddress remote = socket.getInetAddress();
        if (lan) {
            synchronized (lanPerAddress) {
                int open = lanPerAddress.containsKey(remote) ? lanPerAddress.get(remote) : 0;
                if (open >= MAX_LAN_PER_ADDRESS) { closeQuietly(socket); return; }
                lanPerAddress.put(remote, open + 1);
            }
        }
        Runnable task = () -> {
            try { serve(socket, lan); }
            finally { if (lan) release(remote); }
        };
        try { (lan ? lanClients : loopbackClients).execute(task); }
        catch (RejectedExecutionException error) { closeQuietly(socket); if (lan) release(remote); }
    }

    private static void release(InetAddress remote) {
        synchronized (lanPerAddress) {
            Integer open = lanPerAddress.get(remote);
            if (open == null || open <= 1) lanPerAddress.remove(remote); else lanPerAddress.put(remote, open - 1);
        }
    }

    private static void closeQuietly(Socket socket) { try { socket.close(); } catch (IOException ignored) { } }

    static boolean enabled() { return context != null && context.getSharedPreferences("bridge", 0).getBoolean("enabled", true); }

    static synchronized void add(JSONObject event) {
        if (!enabled()) return;
        try {
            event.put("sequence", ++sequence);
            events.addLast(event);
            while (events.size() > 200) events.removeFirst();
        } catch (Exception ignored) { }
    }

    static synchronized void clear() { events.clear(); }

    private static synchronized String response(long after, boolean health) throws Exception {
        JSONObject result = new JSONObject();
        result.put("session", SESSION);
        result.put("protocolVersion", PROTOCOL);
        result.put("lanCertificate", WifiBridge.certificate);
        result.put("lanIdentity", WifiBridge.identity);
        result.put("lanPort", WifiBridge.PORT);
        result.put("sequence", sequence);
        result.put("connected", listenerConnected);
        result.put("enabled", enabled());
        JSONArray items = new JSONArray();
        JSONObject icons = new JSONObject();
        if (!health && enabled()) for (JSONObject item : events) {
            if (item.getLong("sequence") <= after) continue;
            JSONObject copy = new JSONObject();
            Iterator<String> keys = item.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                if (!key.equals("icon")) copy.put(key, item.get(key));
            }
            items.put(copy);
            if (item.has("icon")) icons.put(item.getString("package"), item.getString("icon"));
        }
        result.put("events", items);
        result.put("icons", icons);
        return result.toString();
    }

    private static String line(InputStream in) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        int value;
        while ((value = in.read()) != -1) {
            if (value == '\n') break;
            if (value != '\r') bytes.write(value);
            if (bytes.size() > 4096) throw new IOException("Request too large");
        }
        return bytes.toString("UTF-8");
    }

    private static void serve(Socket socket, boolean lan) {
        // A hard deadline for the unauthenticated phase: slow clients are closed
        // even if they keep trickling bytes under the per-read timeout.
        ScheduledFuture<?> deadline = deadlines.schedule(() -> closeQuietly(socket), HEADER_DEADLINE_MS, TimeUnit.MILLISECONDS);
        try (Socket client = socket) {
            if (client instanceof SSLSocket) ((SSLSocket)client).startHandshake();
            InputStream input = new BufferedInputStream(client.getInputStream(), 4096);
            String request = line(input);
            String auth = "";
            for (int i = 0; i < 32; i++) {
                String header = line(input);
                if (header.isEmpty()) break;
                int colon = header.indexOf(':');
                if (colon > 0 && header.substring(0, colon).equalsIgnoreCase("Authorization"))
                    auth = header.substring(colon + 1).trim();
                if (i == 31) throw new IOException("Too many headers");
            }
            String token = context.getSharedPreferences("bridge", 0).getString("token", "");
            if (token.length() != 64 || !MessageDigest.isEqual(
                ("Bearer " + token).getBytes(StandardCharsets.UTF_8), auth.getBytes(StandardCharsets.UTF_8))) {
                send(client, 401, "{\"error\":\"unauthorized\"}"); return;
            }
            deadline.cancel(false);
            ConnectionService.clientActive();
            String[] parts = request.split(" ");
            if (parts.length < 2) {
                send(client, 405, "{\"error\":\"method\"}"); return;
            }
            URI uri = URI.create(parts[1]);
            String path = uri.getPath();
            if (parts[0].equals("GET") && path.equals("/files")) {
                JSONObject manifest = new JSONObject(); manifest.put("files", FileOutbox.list(context));
                send(client, 200, manifest.toString()); return;
            }
            if (path.matches("/files/[0-9a-f-]{36}/ack") && parts[0].equals("POST")) {
                String query = uri.getQuery();
                if (query == null || !query.matches("sha256=[0-9a-f]{64}")) {
                    send(client, 400, "{\"error\":\"invalid hash\"}"); return;
                }
                boolean ok = FileOutbox.acknowledge(context, path.split("/")[2], query.substring(7));
                send(client, ok ? 200 : 409, "{\"saved\":" + ok + "}"); return;
            }
            if (parts[0].equals("GET") && path.matches("/files/[0-9a-f-]{36}")) {
                File data = FileOutbox.data(context, path.substring(7));
                long offset = 0; int length = 1048576;
                String query = uri.getQuery();
                if (query != null) for (String value : query.split("&")) {
                    if (value.startsWith("offset=")) offset = Long.parseLong(value.substring(7));
                    if (value.startsWith("length=")) length = Integer.parseInt(value.substring(7));
                }
                if (offset < 0 || offset > data.length() || length < 1 || length > 1048576) {
                    send(client, 416, "{\"error\":\"invalid range\"}"); return;
                }
                int count = (int)Math.min(length, data.length() - offset);
                OutputStream out = client.getOutputStream();
                out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + count
                    + "\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                try (RandomAccessFile in = new RandomAccessFile(data, "r")) {
                    in.seek(offset); byte[] bytes = new byte[65536];
                    while (count > 0) {
                        int n = in.read(bytes, 0, Math.min(count, bytes.length));
                        if (n < 0) throw new EOFException();
                        out.write(bytes, 0, n); count -= n;
                    }
                }
                out.flush(); return;
            }
            if (!parts[0].equals("GET")) { send(client, 405, "{\"error\":\"method\"}"); return; }
            if (!uri.getPath().equals("/events") && !uri.getPath().equals("/health")) {
                send(client, 404, "{\"error\":\"not found\"}"); return;
            }
            long after = 0;
            String query = uri.getQuery();
            if (query != null && query.startsWith("after=")) after = Long.parseLong(query.substring(6));
            send(client, 200, response(after, uri.getPath().equals("/health")));
        } catch (Exception error) {
            if (error instanceof javax.net.ssl.SSLException && lan) android.util.Log.w("AndroidWireless", "TLS handshake failed", error);
        } finally {
            deadline.cancel(false);
        }
    }

    private static void send(Socket client, int status, String body) throws IOException {
        byte[] data = body.getBytes(StandardCharsets.UTF_8);
        OutputStream out = client.getOutputStream();
        String headers = "HTTP/1.1 " + status + " Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: "
            + data.length + "\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n";
        out.write(headers.getBytes(StandardCharsets.US_ASCII)); out.write(data); out.flush();
    }
}
