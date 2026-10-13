package local.androidwireless.bridge;
import android.content.*;
public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) { ConnectionService.ensure(context); }
}
