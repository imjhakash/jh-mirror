package com.johirulhoqakash.jhmirror;
public final class TouchGuardConfigTest {
    static void check(boolean ok) { if(!ok)throw new AssertionError(); }
    public static void main(String[] args) {
        String others="other.one/.Reader:other.two/other.two.Touch";
        String full="com.johirulhoqakash.jhmirror/com.johirulhoqakash.jhmirror.TouchGuardService";
        check(TouchGuardConfig.contains(full));
        check(TouchGuardConfig.without(others+":"+full).equals(others));
        check(TouchGuardConfig.with(TouchGuardConfig.with(others)).equals(others+":"+TouchGuardConfig.COMPONENT));
        check(TouchGuardConfig.with(null).equals(TouchGuardConfig.COMPONENT));
        check(TouchGuardConfig.without(TouchGuardConfig.COMPONENT).equals(""));
        check(!TouchGuardConfig.contains(others));
        System.out.println("PASS: touch-service recovery preserves other accessibility components, normalizes our aliases and avoids duplicates");
    }
}
