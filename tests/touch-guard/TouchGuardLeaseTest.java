package com.johirulhoqakash.jhmirror;

public final class TouchGuardLeaseTest {
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        TouchGuardLease lease = new TouchGuardLease();
        String first = "0123456789abcdef0123456789abcdef", second = "abcdef0123456789abcdef0123456789";
        check(!lease.begin(null, 1) && !lease.begin("invalid", 1), "malformed lease rejected");
        check(lease.begin(first, 100), "fresh session arms");
        check(lease.active(8099) && !lease.active(8100), "eight-second exact expiry");
        check(!lease.renew(first, 8100), "expired lease cannot rearm");
        check(!lease.begin(first, 8101), "same session cannot replay begin after expiry");
        check(lease.begin(second, 9000), "a new session can arm");
        check(!lease.renew(first, 9001), "other session cannot extend guard");
        check(lease.renew(second, 12000), "current live session renews");
        check(lease.active(19999) && !lease.active(20000), "renewal deadline");
        lease.release();
        check(!lease.active(12001) && !lease.renew(second, 12001), "power / stop release cannot be undone by a queued renewal");
        check(!lease.begin(second, 12001), "power release cannot be undone by replaying begin");
        check(!new TouchGuardLease().active(0), "restart starts unguarded");
        System.out.println("PASS: touch guard expiry, renewal, wrong-session rejection, power release and replay protection.");
    }
}
