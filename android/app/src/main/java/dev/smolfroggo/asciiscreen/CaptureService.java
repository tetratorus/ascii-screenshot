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
import android.os.PowerManager;
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
import java.util.concurrent.atomic.AtomicReference;

/**
 * Screenshot via the accessibility API on a fixed 1 s clock and append one JSON line per capture to
 * files/capture.jsonl. OCR runs on its own thread on the newest changed frame, so slow OCR shows up
 * as superseded frames instead of slowing the capture clock. Capture pauses while the display is off.
 */
public class CaptureService extends AccessibilityService {
    static final String TAG = "AsciiScreen";
    static final String LOG_FILE = "capture.jsonl";
    private static final long INTERVAL_MS = 1000;
    private static final long REQUEST_TIMEOUT_MS = 5000;
    /** The platform rejects requests closer than 333 ms apart with ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT. */
    private static final long MIN_GAP_MS = 400;

    private record Frame(long n, int[] px, int w, int h, long capturedAt) {}

    private HandlerThread captureThread, ocrThread;
    private Handler capture, ocrHandler;
    private Ocr ocr;
    private Writer log;
    private volatile String foregroundPackage = "?";
    private final AtomicReference<Frame> pending = new AtomicReference<>();
    private long lastHash, frames, nextAt, superseded, inFlightSince, lastRequestAt = -MIN_GAP_MS, requestId;
    private boolean ticking, inFlight;
    private volatile boolean destroyed;
    private final Runnable tick = this::tick;
    private final Runnable runOcr = this::runOcr;

    private final BroadcastReceiver screenEvents = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            String a = i.getAction();
            capture.post(() -> {
                write(event(a.replace("android.intent.action.", "")));
                if (Intent.ACTION_SCREEN_OFF.equals(a)) stopTicking();
                else startTicking();
            });
        }
    };

    @Override protected void onServiceConnected() {
        try {
            log = new OutputStreamWriter(new FileOutputStream(new File(getFilesDir(), LOG_FILE), true), StandardCharsets.UTF_8);
        } catch (IOException e) {
            Log.e(TAG, "log open failed", e);
            return;
        }
        captureThread = new HandlerThread("capture");
        captureThread.start();
        capture = new Handler(captureThread.getLooper());
        ocrThread = new HandlerThread("ocr");
        ocrThread.start();
        ocrHandler = new Handler(ocrThread.getLooper());
        ocrHandler.post(() -> {
            try {
                ocr = new Ocr(this, 4);
            } catch (IOException e) {
                Log.e(TAG, "ocr init failed", e);
                write(event("OCR_INIT_FAILED"));
            }
        });
        write(event("SERVICE_CONNECTED"));
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        f.addAction(Intent.ACTION_USER_PRESENT);
        registerReceiver(screenEvents, f, null, capture, Context.RECEIVER_NOT_EXPORTED);
        boolean on = getSystemService(PowerManager.class).isInteractive();
        capture.post(() -> { if (on) startTicking(); else write(event("PAUSED_SCREEN_OFF")); });
    }

    private void startTicking() {
        if (ticking) return;
        ticking = true;
        nextAt = SystemClock.uptimeMillis();
        capture.post(tick);
    }

    private void stopTicking() {
        ticking = false;
        capture.removeCallbacks(tick);
    }

    /** Fixed-rate clock: one request per slot; a slot whose previous request has not returned yet is logged as missed. */
    private void tick() {
        if (!ticking) return;
        long now = SystemClock.uptimeMillis();
        if (inFlight && now - inFlightSince > REQUEST_TIMEOUT_MS) {
            inFlight = false;
            write(event("SCREENSHOT_TIMEOUT"));
        }
        if (inFlight || now - lastRequestAt < MIN_GAP_MS) {
            JSONObject j = base();
            put(j, "missed_slot", inFlight ? "in_flight" : "too_soon");
            write(j);
        } else {
            request(now);
        }
        nextAt += INTERVAL_MS;
        if (nextAt <= now) nextAt = now + INTERVAL_MS;
        capture.postAtTime(tick, nextAt);
    }

    private void request(long requestedAt) {
        long id = ++requestId;
        inFlight = true;
        inFlightSince = lastRequestAt = requestedAt;
        takeScreenshot(Display.DEFAULT_DISPLAY, capture::post, new TakeScreenshotCallback() {
            @Override public void onSuccess(ScreenshotResult r) {
                try (HardwareBuffer hb = r.getHardwareBuffer()) {
                    if (stale(id)) return;
                    Bitmap hw = Bitmap.wrapHardwareBuffer(hb, r.getColorSpace());
                    Bitmap bmp = hw.copy(Bitmap.Config.ARGB_8888, false);
                    hw.recycle();
                    int w = bmp.getWidth(), h = bmp.getHeight();
                    int[] px = new int[w * h];
                    bmp.getPixels(px, 0, w, 0, 0, w, h);
                    bmp.recycle();
                    captured(px, w, h, requestedAt);
                } catch (RuntimeException e) {
                    Log.e(TAG, "frame failed", e);
                    JSONObject j = base();
                    put(j, "frame_error", e.toString());
                    write(j);
                }
            }

            @Override public void onFailure(int code) {
                if (stale(id)) return;
                JSONObject j = base();
                put(j, "screenshot_error", code);
                write(j);
            }
        });
    }

    /** A result for a request that already timed out is dropped so it cannot clear a newer request's in-flight state. */
    private boolean stale(long id) {
        if (id == requestId && inFlight) {
            inFlight = false;
            return false;
        }
        write(event("LATE_SCREENSHOT_DROPPED"));
        return true;
    }

    private void captured(int[] px, int w, int h, long requestedAt) {
        long hash = 1125899906842597L;
        for (int i = 0; i < px.length; i += 7) hash = 31 * hash + px[i];
        long n = frames++;
        JSONObject j = base();
        put(j, "frame", n);
        put(j, "capture_ms", SystemClock.uptimeMillis() - requestedAt);
        if (hash == lastHash) {
            put(j, "unchanged", true);
        } else {
            lastHash = hash;
            Frame old = pending.getAndSet(new Frame(n, px, w, h, SystemClock.uptimeMillis()));
            if (old != null) {
                superseded++;
                put(j, "ocr_superseded_frame", old.n());
            }
            ocrHandler.post(runOcr);
        }
        write(j);
    }

    private void runOcr() {
        Frame f = pending.getAndSet(null);
        if (f == null || ocr == null) return;
        long t0 = SystemClock.uptimeMillis();
        List<Ocr.Line> lines = ocr.run(f.px(), f.w(), f.h());
        long done = SystemClock.uptimeMillis();
        if (destroyed) return;
        JSONArray arr = new JSONArray();
        for (Ocr.Line l : lines) {
            JSONObject o = new JSONObject();
            put(o, "text", l.text());
            put(o, "box", new JSONArray().put(l.x0()).put(l.y0()).put(l.x1()).put(l.y1()));
            arr.put(o);
        }
        JSONObject j = base();
        put(j, "ocr_frame", f.n());
        put(j, "ocr_ms", done - t0);
        put(j, "lag_ms", done - f.capturedAt());
        put(j, "det_runs", ocr.detRuns);
        put(j, "rec_runs", ocr.recRuns);
        put(j, "lines", arr);
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

    private synchronized void write(JSONObject j) {
        if (log == null) return;
        try { log.write(j.toString()); log.write('\n'); log.flush(); } catch (IOException e) { Log.e(TAG, "write failed", e); }
    }

    private synchronized void closeLog() {
        if (log == null) return;
        try { log.close(); } catch (IOException e) { Log.e(TAG, "close failed", e); }
        log = null;
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) {
        if (e.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && e.getPackageName() != null) {
            foregroundPackage = e.getPackageName().toString();
        }
    }

    @Override public void onInterrupt() {}

    @Override public void onDestroy() {
        if (capture != null) {
            destroyed = true;
            unregisterReceiver(screenEvents);
            JSONObject j = event("SERVICE_DESTROYED");
            put(j, "frames", frames);
            put(j, "ocr_superseded", superseded);
            write(j);
            capture.post(this::stopTicking);
            captureThread.quitSafely();
            // An OCR pass already running cannot be interrupted; its result is discarded and resources close after it.
            pending.set(null);
            ocrHandler.post(() -> {
                if (ocr != null) ocr.close();
                closeLog();
            });
            ocrThread.quitSafely();
        }
        super.onDestroy();
    }
}
