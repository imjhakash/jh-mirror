package com.johirulhoqakash.jhmirror;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.widget.*;

/** Small native view toolkit: no web view, image assets or third-party UI runtime. */
final class PhoneUi {
    final Context context;
    final boolean dark;
    final int background, surface, text, muted, accent = Color.rgb(40, 117, 229);
    PhoneUi(Context context) {
        this.context = context;
        String theme = context.getSharedPreferences("bridge", 0).getString("uiTheme", "system");
        dark = "dark".equals(theme) || "system".equals(theme) && (context.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        background = Color.rgb(dark ? 17 : 244, dark ? 21 : 247, dark ? 29 : 251);
        surface = Color.rgb(dark ? 29 : 255, dark ? 35 : 255, dark ? 46 : 255);
        text = Color.rgb(dark ? 237 : 23, dark ? 242 : 35, dark ? 250 : 54);
        muted = Color.rgb(dark ? 163 : 102, dark ? 177 : 117, dark ? 196 : 138);
    }
    int dp(float value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
    LinearLayout column() { LinearLayout view = new LinearLayout(context); view.setOrientation(LinearLayout.VERTICAL); return view; }
    TextView text(String value, int size, boolean bold) {
        TextView view = new TextView(context); view.setText(value); view.setTextSize(size); view.setTextColor(text);
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        view.setLineSpacing(dp(2), 1); view.setPadding(0, dp(3), 0, dp(3)); return view;
    }
    TextView note(String value) { TextView view = text(value, 13, false); view.setTextColor(muted); return view; }
    GradientDrawable rounded(int color, int radius) { GradientDrawable value = new GradientDrawable(); value.setColor(color); value.setCornerRadius(dp(radius)); return value; }
    LinearLayout card(LinearLayout parent) {
        LinearLayout card = column(); card.setPadding(dp(18), dp(14), dp(18), dp(14)); card.setBackground(rounded(surface, 18));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.bottomMargin = dp(14); parent.addView(card, params); return card;
    }
    Button button(String title, Runnable action) {
        Button button = new Button(context); button.setText(title); button.setAllCaps(false); button.setTextSize(14);
        button.setMinHeight(dp(48)); button.setPadding(dp(12), dp(6), dp(12), dp(6)); styleButton(button, false);
        button.setOnClickListener(v -> action.run()); return button;
    }
    void styleButton(Button button, boolean selected) {
        button.setTextColor(selected ? Color.WHITE : accent);
        button.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x332875E5),
            rounded(selected ? accent : 0x122875E5, 12), null));
    }
    TextView heading(LinearLayout parent, String title) { TextView view = text(title, 17, true); parent.addView(view); return view; }
    int signal(String state) { return "green".equals(state) ? Color.rgb(32, 161, 105) : "red".equals(state) ? Color.rgb(218, 65, 76) : Color.rgb(211, 144, 24); }
}
