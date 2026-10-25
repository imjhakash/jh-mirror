import com.genymobile.scrcpy.JHMediaQuery;
public final class MediaQueryCheck {
    public static void main(String[] args) {
        for (int sdk = 26; sdk <= 36; sdk++) {
            String value = JHMediaQuery.selection(sdk);
            if (!value.startsWith("media_type=?") || value.contains("is_pending") != (sdk >= 29)
                || value.contains("is_trashed") != (sdk >= 30)) throw new AssertionError("Unsupported MediaStore column at API " + sdk);
        }
        System.out.println("PASS: Android 8–16 MediaStore queries never reference columns absent on older Samsung releases");
    }
}
