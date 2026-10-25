package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.nsd.*;
import android.security.keystore.*;
import android.util.Base64;
import java.math.BigInteger;
import java.security.*;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.util.*;
import javax.net.ssl.*;
import javax.security.auth.x500.X500Principal;

/** The private key never leaves Android Keystore. The Mac learns the certificate
 * only through its already authenticated ADB tunnel, then pins it for LAN use. */
final class WifiBridge {
    static final int PORT = 38476;
    private static final String ALIAS = "jh-mirror-lan";
    private static SSLServerSocket server;
    private static NsdManager manager;
    private static NsdManager.RegistrationListener registration;
    static String certificate = "";
    static String identity = "";

    static synchronized void start(Context context) {
        if (server != null && !server.isClosed()) return;
        if (context.getSharedPreferences("bridge", 0).getString("token", "").length() != 64) return;
        try {
            KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null);
            if (!keys.containsAlias(ALIAS)) {
                KeyPairGenerator generator = KeyPairGenerator.getInstance("EC", "AndroidKeyStore");
                generator.initialize(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(new X500Principal("CN=JH Mirror"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(new Date(1577836800000L))
                    .setCertificateNotAfter(new Date(2208988800000L)).build());
                generator.generateKeyPair();
            }
            PrivateKey key = (PrivateKey) keys.getKey(ALIAS, null);
            X509Certificate cert = (X509Certificate) keys.getCertificate(ALIAS);
            certificate = Base64.encodeToString(cert.getEncoded(), Base64.NO_WRAP);
            X509ExtendedKeyManager keyManager = new X509ExtendedKeyManager() {
                public String[] getClientAliases(String type, java.security.Principal[] issuers) { return null; }
                public String chooseClientAlias(String[] types, java.security.Principal[] issuers, java.net.Socket socket) { return null; }
                public String[] getServerAliases(String type, java.security.Principal[] issuers) { return "EC".equals(type) ? new String[]{ALIAS} : null; }
                public String chooseServerAlias(String type, java.security.Principal[] issuers, java.net.Socket socket) { return type.startsWith("EC") ? ALIAS : null; }
                public String chooseEngineServerAlias(String type, java.security.Principal[] issuers, SSLEngine engine) { return type.startsWith("EC") ? ALIAS : null; }
                public X509Certificate[] getCertificateChain(String alias) { return ALIAS.equals(alias) ? new X509Certificate[]{cert} : null; }
                public PrivateKey getPrivateKey(String alias) { return ALIAS.equals(alias) ? key : null; }
            };
            SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(new KeyManager[]{keyManager}, null, new SecureRandom());
            SSLServerSocket listener = (SSLServerSocket)tls.getServerSocketFactory().createServerSocket();
            listener.setReuseAddress(true);
            listener.bind(new java.net.InetSocketAddress(PORT), 16);
            listener.setEnabledProtocols(android.os.Build.VERSION.SDK_INT >= 29 ? new String[]{"TLSv1.2", "TLSv1.3"} : new String[]{"TLSv1.2"});
            server = listener;
            Thread accept = new Thread(() -> {
                while (!listener.isClosed()) {
                    try { BridgeState.accept(listener.accept(), true); }
                    catch (Exception error) {
                        if (listener.isClosed()) break;
                        android.util.Log.w("JHMirror", "LAN accept", error);
                        // Avoid a hot loop on persistent errors such as descriptor exhaustion.
                        try { Thread.sleep(200); } catch (InterruptedException stop) { break; }
                    }
                }
                synchronized (WifiBridge.class) { if (server == listener) server = null; }
            }, "wireless-encrypted-wifi");
            accept.setDaemon(true); accept.start();
            SharedPreferences prefs = context.getSharedPreferences("bridge", 0);
            identity = prefs.getString("lanIdentity", "");
            if (identity.isEmpty()) {
                identity = "AW-" + UUID.randomUUID().toString().replace("-", "");
                prefs.edit().putString("lanIdentity", identity).commit();
            }
            if (registration != null) return;
            manager = (NsdManager)context.getSystemService(Context.NSD_SERVICE);
            NsdServiceInfo service = new NsdServiceInfo();
            service.setServiceName(identity); service.setServiceType("_jhmirror._tcp."); service.setPort(PORT);
            registration = new NsdManager.RegistrationListener() {
                public void onServiceRegistered(NsdServiceInfo info) { }
                public void onRegistrationFailed(NsdServiceInfo info, int error) {
                    // Allow a later start() (for example on the next Wi-Fi change) to retry.
                    synchronized (WifiBridge.class) { registration = null; }
                }
                public void onServiceUnregistered(NsdServiceInfo info) { }
                public void onUnregistrationFailed(NsdServiceInfo info, int error) { }
            };
            manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration);
        } catch (Exception error) {
            android.util.Log.e("JHMirror", "Could not start encrypted Wi-Fi bridge", error);
            if (server != null) try { server.close(); } catch (Exception ignored) { }
            server = null;
        }
    }
}
