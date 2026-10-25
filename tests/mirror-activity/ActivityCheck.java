import com.genymobile.scrcpy.control.ControlMessage;
import com.genymobile.scrcpy.control.ControlMessageReader;
import java.io.ByteArrayInputStream;
public final class ActivityCheck {
    public static void main(String[] args) throws Exception {
        ControlMessageReader reader = new ControlMessageReader(new ByteArrayInputStream(new byte[]{(byte)200,5,(byte)201,11}));
        if (reader.read().getType()!=ControlMessage.TYPE_JH_KEEP_ACTIVE || reader.read().getType()!=5
            || reader.read().getType()!=ControlMessage.TYPE_JH_RELEASE_DISPLAY || reader.read().getType()!=11) throw new AssertionError("activity pulse framing");
        System.out.println("PASS: Android reads unsigned one-byte activity pulses without consuming adjacent control messages.");
    }
}
