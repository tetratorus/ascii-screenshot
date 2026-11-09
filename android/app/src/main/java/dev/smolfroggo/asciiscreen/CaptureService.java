package dev.smolfroggo.asciiscreen;

import android.accessibilityservice.AccessibilityService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.hardware.HardwareBuffer;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.Log;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;

/** Screenshot via the accessibility API every second, OCR it, append one JSON line per frame to files/capture.jsonl. */
public class CaptureService extends AccessibilityService {
    static final String TAG = "AsciiScreen";
    static final String LOG_FILE = "capture.jsonl";
    private static final long INTERVAL_MS = 1000;

    private HandlerThread thread;
    private Handler handler;
    private Ocr ocr;
    private Writer log;
    private volatile String foregroundPackage = "?";
    private long lastHash;
    private long frames;
    private final Runnable tick = this::capture;

    private final BroadcastReceiver screenEvents = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            handler.post(() -> write(event(i.getAction().replace("android.intent.action.", ""))));
        }
    };

    @Override protected void onServiceConnected() {
        thread = new HandlerThread("capture");
        thread.start();
        handler = new Handler(thread.getLooper());
        handler.post(() -> {
            try {
                log = new OutputStreamWriter(new FileOutputStream(new File(getFilesDir(), LOG_FILE), true), StandardCharsets.UTF_8);
                ocr = new Ocr(this, 4);
                write(event("SERVICE_CONNECTED"));
            } catch (IOException e) {
                Log.e(TAG, "init failed", e);
                return;
            }
            handler.post(tick);
        });
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        f.addAction(Intent.ACTION_USER_PRESENT);
        registerReceiver(screenEvents, f, Context.RECEIVER_NOT_EXPORTED);
    }

    private void capture() {
        long start = SystemClock.uptimeMillis();
        takeScreenshot(Display.DEFAULT_DISPLAY, handler::post, new TakeScreenshotCallback() {
            @Override public void onSuccess(ScreenshotResult r) {
                try (HardwareBuffer hb = r.getHardwareBuffer()) {
                    Bitmap hw = Bitmap.wrapHardwareBuffer(hb, r.getColorSpace());
                    Bitmap bmp = hw.copy(Bitmap.Config.ARGB_8888, false);
                    hw.recycle();
                    process(bmp, start);
                    bmp.recycle();
                } catch (RuntimeException e) {
                    Log.e(TAG, "frame failed", e);
                }
                next(start);
            }

            @Override public void onFailure(int code) {
                JSONObject j = base();
                put(j, "screenshot_error", code);
                write(j);
                next(start);
            }
        });
    }

    private void next(long start) {
        handler.postDelayed(tick, Math.max(0, INTERVAL_MS - (SystemClock.uptimeMillis() - start)));
    }

    private void process(Bitmap bmp, long start) {
        int w = bmp.getWidth(), h = bmp.getHeight();
        int[] px = new int[w * h];
        bmp.getPixels(px, 0, w, 0, 0, w, h);
        long hash = 1125899906842597L;
        for (int i = 0; i < px.length; i += 7) hash = 31 * hash + px[i];
        JSONObject j = base();
        put(j, "frame", frames++);
        if (hash == lastHash) {
            put(j, "unchanged", true);
        } else {
            lastHash = hash;
            long t0 = SystemClock.uptimeMillis();
            List<Ocr.Line> lines = ocr.run(px, w, h);
            JSONArray arr = new JSONArray();
            for (Ocr.Line l : lines) {
                JSONObject o = new JSONObject();
                put(o, "text", l.text());
                put(o, "box", new JSONArray().put(l.x0()).put(l.y0()).put(l.x1()).put(l.y1()));
                arr.put(o);
            }
            put(j, "ocr_ms", SystemClock.uptimeMillis() - t0);
            put(j, "det_runs", ocr.detRuns);
            put(j, "rec_runs", ocr.recRuns);
            put(j, "lines", arr);
        }
        put(j, "total_ms", SystemClock.uptimeMillis() - start);
        write(j);
    }

    private JSONObject base() {
        JSONObject j = new JSONObject();
        put(j, "t", Instant.now().toString());
        put(j, "pkg", foregroundPackage);
        return j;
    }

    private JSONObject event(String name) {
        JSONObject j = base();
        put(j, "event", name);
        return j;
    }

    private static void put(JSONObject j, String k, Object v) {
        try { j.put(k, v); } catch (JSONException e) { throw new IllegalStateException(e); }
    }

    private void write(JSONObject j) {
        if (log == null) return;
        try { log.write(j.toString()); log.write('\n'); log.flush(); } catch (IOException e) { Log.e(TAG, "write failed", e); }
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) {
        if (e.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && e.getPackageName() != null) {
            foregroundPackage = e.getPackageName().toString();
        }
    }

    @Override public void onInterrupt() {}

    @Override public void onDestroy() {
        unregisterReceiver(screenEvents);
        if (handler != null) handler.post(() -> {
            write(event("SERVICE_DESTROYED"));
            if (ocr != null) ocr.close();
            thread.quitSafely();
        });
        super.onDestroy();
    }
}
