package dev.smolfroggo.asciiscreen;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    private static final int TAIL_BYTES = 4000;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView tail;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setFitsSystemWindows(true);
        Button open = new Button(this);
        open.setText("Open accessibility settings");
        open.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        root.addView(open);
        tail = new TextView(this);
        tail.setTextSize(10);
        ScrollView sv = new ScrollView(this);
        sv.addView(tail);
        root.addView(sv);
        setContentView(root);
    }

    @Override protected void onResume() { super.onResume(); refresh(); }
    @Override protected void onPause() { super.onPause(); ui.removeCallbacksAndMessages(null); }

    private void refresh() {
        File f = new File(getFilesDir(), CaptureService.LOG_FILE);
        String text = "No capture yet. Enable \"AsciiScreen capture\" in accessibility settings.";
        if (f.exists()) try (RandomAccessFile r = new RandomAccessFile(f, "r")) {
            long start = Math.max(0, r.length() - TAIL_BYTES);
            byte[] buf = new byte[(int) (r.length() - start)];
            r.seek(start);
            r.readFully(buf);
            text = new String(buf, StandardCharsets.UTF_8);
        } catch (IOException e) { text = e.toString(); }
        tail.setText(text);
        ui.postDelayed(this::refresh, 1000);
    }
}
