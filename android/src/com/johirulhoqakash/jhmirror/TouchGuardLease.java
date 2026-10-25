package com.johirulhoqakash.jhmirror;

/** An in-memory lease. Renewals can never re-arm an expired or locally released guard. */
final class TouchGuardLease {
    static final long TIMEOUT_MS = 8000;
    private String token;
    private long deadline;
    boolean begin(String value, long now) {
        if (value == null || !value.matches("[a-f0-9]{32}") || value.equals(token)) return false;
        token = value; deadline = now + TIMEOUT_MS; return true;
    }
    boolean renew(String value, long now) {
        if (!active(now) || !token.equals(value)) return false;
        deadline = now + TIMEOUT_MS; return true;
    }
    boolean active(long now) { return deadline > now; }
    boolean matches(String value) { return token != null && token.equals(value); }
    void release() { deadline = 0; }
}
