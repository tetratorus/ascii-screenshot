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

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.LinkedBlockingDeque;

/**
 * Screenshot via the accessibility API on a fixed 1 s clock and append one JSON line per capture to
 * files/capture.jsonl. Every changed frame is read, in order, on its own thread by {@link Pipeline}, which only
 * re-reads what changed. No frame is ever dropped: a waiting frame is kept as just its changed tiles, in memory up to
 * MEMORY_BUDGET and in app-private files beyond that, and frames still waiting at shutdown are read before the OCR
 * thread exits. Capture pauses while the display is off.
 */
public class CaptureService extends AccessibilityService {
    static final String TAG = "AsciiScreen";
    static final String LOG_FILE = "capture.jsonl";
    private static final long INTERVAL_MS = 1000;
    private static final long REQUEST_TIMEOUT_MS = 5000;
    /** The platform rejects requests closer than 333 ms apart with ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT. */
    private static final long MIN_GAP_MS = 400;
    /** Waiting patches beyond this many bytes are written to disk instead of held in memory. */
    private static final long MEMORY_BUDGET = 48L << 20;
    /** Waiting frames read together; each is rebuilt as a full ~10 MB frame while it is read. */
    private static final int MAX_BATCH = 4;

    /** A changed frame waiting to be read: its patch in memory, or in spill when patch is null. */
    private record Frame(long n, long capturedAt, FramePatch patch, File spill, long bytes) {}

    private HandlerThread captureThread, ocrThread;
    private Handler capture, ocrHandler;
    private Ocr ocr;
    private Pipeline pipeline;
    private Writer log;
    private volatile String foregroundPackage = "?";
    private final LinkedBlockingDeque<Frame> pending = new LinkedBlockingDeque<>();
    private int[] lastPx, ocrPx;
    private int lastW, lastH;
    private File spillDir;
    private final java.util.concurrent.atomic.AtomicLong queuedBytes = new java.util.concurrent.atomic.AtomicLong();
    private volatile boolean resync;
    private long frames, nextAt, spilled, lost, inFlightSince, lastRequestAt = -MIN_GAP_MS, requestId;
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
        spillDir = new File(getNoBackupFilesDir(), "backlog");
        deleteSpill();
        captureThread = new HandlerThread("capture");
        captureThread.start();
        capture = new Handler(captureThread.getLooper());
        ocrThread = new HandlerThread("ocr");
        ocrThread.start();
        ocrHandler = new Handler(ocrThread.getLooper());
        ocrHandler.post(() -> {
            try {
                ocr = new Ocr(this, 4);
                pipeline = new Pipeline(ocr);
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
        long n = frames++;
        JSONObject j = base();
        put(j, "frame", n);
        put(j, "capture_ms", SystemClock.uptimeMillis() - requestedAt);
        if (resync) { resync = false; lastPx = null; }
        FramePatch p = FramePatch.diff(lastPx, lastW, lastH, px, w, h);
        if (p == null) {
            put(j, "unchanged", true);
        } else {
            lastPx = px; lastW = w; lastH = h;
            put(j, "changed_tiles", p.changedTiles());
            long now = SystemClock.uptimeMillis();
            Frame f;
            if (!pending.isEmpty() && queuedBytes.get() + p.bytes() > MEMORY_BUDGET && (f = spill(n, now, p)) != null) {
                spilled++;
                put(j, "spilled", true);
            } else {
                queuedBytes.addAndGet(p.bytes());
                f = new Frame(n, now, p, null, p.bytes());
            }
            pending.addLast(f);
            put(j, "queued", pending.size());
            put(j, "queued_kb", queuedBytes.get() / 1024);
            ocrHandler.post(runOcr);
        }
        write(j);
    }

    /** Write the patch to app-private storage; null (keep it in memory) if that fails. */
    private Frame spill(long n, long now, FramePatch p) {
        File file = new File(spillDir, n + ".patch");
        try {
            spillDir.mkdirs();
            try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file), 1 << 16))) {
                p.write(out);
            }
            return new Frame(n, now, null, file, 0);
        } catch (IOException e) {
            Log.e(TAG, "spill failed", e);
            file.delete();
            return null;
        }
    }

    private FramePatch load(Frame f) throws IOException {
        if (f.patch() != null) { queuedBytes.addAndGet(-f.bytes()); return f.patch(); }
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(f.spill()), 1 << 16))) {
            return FramePatch.read(in);
        } finally {
            f.spill().delete();
        }
    }

    private void deleteSpill() {
        File[] old = spillDir.listFiles();
        if (old != null) for (File x : old) x.delete();
    }

    /** Read the waiting frames, up to MAX_BATCH at a time, together (see {@link Pipeline#processAll}). */
    private void runOcr() {
        if (pending.isEmpty()) return;
        long t0 = SystemClock.uptimeMillis();
        List<Frame> taken = new ArrayList<>();
        List<Pipeline.Frame> frames = new ArrayList<>();
        while (taken.size() < MAX_BATCH) {
            Frame f = pending.pollFirst();
            if (f == null) break;
            try {
                FramePatch p = load(f);
                ocrPx = p.apply(ocrPx);
                taken.add(f);
                frames.add(new Pipeline.Frame(ocrPx, p.w, p.h));
            } catch (IOException | IllegalStateException e) {
                // Later patches are relative to this frame, so ask capture for a whole frame next time.
                Log.e(TAG, "frame load failed", e);
                lost++;
                resync = true;
                ocrPx = null;
                JSONObject j = base();
                put(j, "ocr_frame", f.n());
                put(j, "frame_lost", e.toString());
                write(j);
                break;
            }
        }
        if (taken.isEmpty()) return;
        if (pipeline == null) {
            for (Frame f : taken) {
                JSONObject j = base();
                put(j, "ocr_frame", f.n());
                put(j, "ocr_unavailable", true);
                write(j);
            }
            return;
        }
        ocr.resetStats();
        List<Pipeline.Result> results = pipeline.processAll(frames);
        long done = SystemClock.uptimeMillis();
        for (int i = 0; i < taken.size(); i++) {
            Pipeline.Result r = results.get(i);
            if (r == null) continue;
            Frame f = taken.get(i);
            JSONArray arr = new JSONArray();
            for (Ocr.Line l : r.lines) {
                JSONObject o = new JSONObject();
                put(o, "text", l.text());
                put(o, "box", new JSONArray().put(l.x0()).put(l.y0()).put(l.x1()).put(l.y1()));
                arr.put(o);
            }
            JSONObject j = base();
            put(j, "ocr_frame", f.n());
            put(j, "mode", r.mode);
            put(j, "regions", r.regions);
            put(j, "rereads", r.rereads);
            JSONArray rects = new JSONArray();
            for (int[] q : r.rects) rects.put(new JSONArray().put(q[0]).put(q[1]).put(q[2]).put(q[3]));
            put(j, "rects", rects);
            put(j, "scroll_dy", r.scrollDy);
            put(j, "moved", r.moved);
            put(j, "area_pct", Math.round(r.areaPct * 10) / 10.0);
            put(j, "batch", taken.size());
            put(j, "det_batch", r.detBatch);
            put(j, "backlog", pending.size());
            put(j, "spilled", f.spill() != null);
            put(j, "ocr_ms", done - t0);
            put(j, "lag_ms", done - f.capturedAt());
            // Model runs and time breakdown are for the whole batch.
            put(j, "det_runs", ocr.detRuns);
            put(j, "rec_runs", ocr.recRuns);
            put(j, "ms", new JSONArray().put(ocr.resizeNs / 1000000).put(ocr.detPrepNs / 1000000).put(ocr.detNs / 1000000)
                    .put(ocr.detPostNs / 1000000).put(ocr.recPrepNs / 1000000).put(ocr.recNs / 1000000));
            put(j, "lines", arr);
            write(j);
        }
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
            put(j, "spilled", spilled);
            put(j, "ocr_backlog", pending.size());
            write(j);
            capture.post(this::stopTicking);
            captureThread.quitSafely();
            // Frames still waiting are read (their OCR runs are already posted) before resources close.
            ocrHandler.post(() -> {
                JSONObject d = event("OCR_DRAINED");
                put(d, "lost", lost);
                write(d);
                if (ocr != null) ocr.close();
                deleteSpill();
                closeLog();
            });
            ocrThread.quitSafely();
        }
        super.onDestroy();
    }
}
