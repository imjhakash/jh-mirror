package com.genymobile.scrcpy;

/** MediaStore columns vary by Android release; never force an old phone into a full-storage scan. */
public final class JHMediaQuery {
    private JHMediaQuery() { }
    public static String selection(int sdk) {
        String value = "media_type=?";
        if (sdk >= 29) value += " AND is_pending=0";
        if (sdk >= 30) value += " AND is_trashed=0";
        return value;
    }
}
