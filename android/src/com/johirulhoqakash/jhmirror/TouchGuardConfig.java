package com.johirulhoqakash.jhmirror;

/** Edits only our component; other accessibility services retain their order and settings. */
final class TouchGuardConfig {
    static final String COMPONENT = "com.johirulhoqakash.jhmirror/.TouchGuardService";
    private static boolean ours(String entry) {
        return COMPONENT.equals(entry) || "com.johirulhoqakash.jhmirror/com.johirulhoqakash.jhmirror.TouchGuardService".equals(entry);
    }
    static boolean contains(String value) {
        if (value != null) for (String entry : value.split(":")) if (ours(entry)) return true;
        return false;
    }
    static String without(String value) {
        StringBuilder result = new StringBuilder();
        if (value != null && !value.equals("null")) for (String entry : value.split(":")) {
            if (entry.isEmpty() || ours(entry)) continue;
            if (result.length() > 0) result.append(':');
            result.append(entry);
        }
        return result.toString();
    }
    static String with(String value) {
        String others = without(value);
        return others.isEmpty() ? COMPONENT : others + ":" + COMPONENT;
    }
}
