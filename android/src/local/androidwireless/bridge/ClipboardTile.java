package local.androidwireless.bridge;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** Quick Settings tile: copy something on the phone, pull down, tap "Copy to Mac". */
public final class ClipboardTile extends TileService {
    @Override public void onStartListening() {
        Tile tile = getQsTile();
        if (tile == null) return;
        tile.setState(Tile.STATE_INACTIVE);
        tile.setLabel("Copy to Mac");
        tile.updateTile();
    }

    @Override public void onClick() {
        Intent intent = new Intent(this, ClipboardActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 3, intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        } else {
            startLegacy(intent);
        }
    }

    @SuppressWarnings("deprecation")
    private void startLegacy(Intent intent) { startActivityAndCollapse(intent); }
}
