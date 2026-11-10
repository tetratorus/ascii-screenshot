package dev.smolfroggo.asciiscreen;

import android.app.Activity;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;

/** Debug-only FLAG_SECURE window for capture tests: am start -n dev.smolfroggo.asciiscreen/.SecureFixtureActivity */
public class SecureFixtureActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        TextView t = new TextView(this);
        t.setTextSize(32);
        t.setPadding(48, 200, 48, 48);
        t.setText("SECRET FIXTURE 12345\n机密测试窗口");
        setContentView(t);
    }
}
