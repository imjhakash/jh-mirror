package com.johirulhoqakash.jhmirror;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/** A transient picker entry; sending from the Mac never leaves the phone dashboard open. */
public final class PickFilesActivity extends Activity {
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        if (saved != null) return;
        try {
            Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            picker.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true); startActivityForResult(picker, 1);
        } catch (RuntimeException unavailable) { android.widget.Toast.makeText(this, "No file picker is available on this phone.", android.widget.Toast.LENGTH_LONG).show(); finish(); }
    }
    @Override public void onActivityResult(int code, int result, Intent data) {
        super.onActivityResult(code, result, data);
        if (code == 1 && result == RESULT_OK && data != null) {
            Intent share = new Intent(this, ShareActivity.class).setAction(getPackageName() + ".PICKED");
            share.setData(data.getData()); share.setClipData(data.getClipData()); share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivity(share);
        }
        finish();
    }
}
