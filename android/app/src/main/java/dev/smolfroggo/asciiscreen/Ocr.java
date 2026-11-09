package dev.smolfroggo.asciiscreen;

import android.content.Context;
import android.content.res.AssetFileDescriptor;

import org.tensorflow.lite.Interpreter;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** PP-OCRv6 small: fixed-shape detector [1,3,1280,608] and recognizer [1,3,48,640], CTC decoding. */
final class Ocr implements AutoCloseable {
    record Line(String text, float conf, int x0, int y0, int x1, int y1) {}

    private static final float[] MEAN = {0.485f, 0.456f, 0.406f};
    private static final float[] STD = {0.229f, 0.224f, 0.225f};
    private static final int TILE_OVERLAP = 96;
    private static final int TILE_EDGE = 48;
    private static final float BIN_THRESHOLD = 0.3f;
    private static final float BOX_THRESHOLD = 0.6f;
    private static final float UNCLIP_RATIO = 1.5f;
    private static final int MIN_COMPONENT_PIXELS = 6;

    private final Interpreter det;
    private final Interpreter rec;
    private final int detH, detW, recH, recW, steps, classes;
    private final String[] vocab;
    private final ByteBuffer detIn, detOut, recIn, recOut;
    private final FloatBuffer detInF, detOutF, recInF, recOutF;

    Ocr(Context ctx, int threads) throws IOException {
        Interpreter.Options o = new Interpreter.Options().setNumThreads(threads);
        det = new Interpreter(map(ctx, "v6_small_det608.tflite"), o);
        rec = new Interpreter(map(ctx, "v6_small_rec640.tflite"), o);
        int[] di = det.getInputTensor(0).shape();
        int[] ri = rec.getInputTensor(0).shape();
        int[] ro = rec.getOutputTensor(0).shape();
        detH = di[2]; detW = di[3]; recH = ri[2]; recW = ri[3]; steps = ro[1]; classes = ro[2];
        List<String> chars = new ArrayList<>();
        chars.add("");
        try (BufferedReader r = new BufferedReader(new InputStreamReader(ctx.getAssets().open("v6_small_dict.txt"), StandardCharsets.UTF_8))) {
            for (String l; (l = r.readLine()) != null; ) chars.add(l);
        }
        if (classes == chars.size() + 1) chars.add(" ");
        vocab = chars.toArray(new String[0]);
        detIn = direct(3 * detH * detW);
        detOut = direct(detH * detW);
        recIn = direct(3 * recH * recW);
        recOut = direct(steps * classes);
        detInF = detIn.asFloatBuffer(); detOutF = detOut.asFloatBuffer();
        recInF = recIn.asFloatBuffer(); recOutF = recOut.asFloatBuffer();
    }

    private static ByteBuffer direct(int floats) {
        return ByteBuffer.allocateDirect(floats * 4).order(ByteOrder.nativeOrder());
    }

    private static MappedByteBuffer map(Context ctx, String name) throws IOException {
        try (AssetFileDescriptor fd = ctx.getAssets().openFd(name);
             FileInputStream in = new FileInputStream(fd.getFileDescriptor())) {
            return in.getChannel().map(FileChannel.MapMode.READ_ONLY, fd.getStartOffset(), fd.getDeclaredLength());
        }
    }

    int detRuns, recRuns;

    /** argb: full-resolution ARGB_8888 pixels, row-major. */
    List<Line> run(int[] argb, int w, int h) {
        detRuns = 0; recRuns = 0;
        List<Line> out = new ArrayList<>();
        for (int[] b : detect(argb, w, h)) {
            int x0 = Math.max(0, b[0]), y0 = Math.max(0, b[1]), x1 = Math.min(w, b[2]), y1 = Math.min(h, b[3]);
            if (x1 - x0 < 3 || y1 - y0 < 3) continue;
            StringBuilder text = new StringBuilder();
            float confSum = 0; int segs = 0;
            for (int[] seg : splitWide(argb, w, x0, y0, x1, y1)) {
                Object[] r = recognize(argb, w, seg[0], y0, seg[1] - seg[0], y1 - y0);
                text.append((String) r[0]); confSum += (float) r[1]; segs++;
            }
            if (text.toString().isBlank()) continue;
            out.add(new Line(text.toString(), confSum / segs, x0, y0, x1, y1));
        }
        return out;
    }

    private List<int[]> detect(int[] argb, int w, int h) {
        float sc = (float) detW / w;
        int rh = Math.round(h * sc);
        int[] rs = resize(argb, w, 0, 0, w, h, detW, rh);
        List<int[]> boxes = new ArrayList<>();
        int step = detH - TILE_OVERLAP;
        for (int y = 0; y < Math.max(1, rh - TILE_OVERLAP); y += step) {
            FloatBuffer in = detInF;
            int plane = detH * detW;
            for (int ty = 0; ty < detH; ty++) {
                int sy = y + ty;
                for (int tx = 0; tx < detW; tx++) {
                    int p = sy < rh ? rs[sy * detW + tx] : 0xff000000;
                    int i = ty * detW + tx;
                    in.put(i, (((p >> 16) & 0xff) / 255f - MEAN[0]) / STD[0]);
                    in.put(plane + i, (((p >> 8) & 0xff) / 255f - MEAN[1]) / STD[1]);
                    in.put(2 * plane + i, ((p & 0xff) / 255f - MEAN[2]) / STD[2]);
                }
            }
            detIn.rewind(); detOut.rewind();
            det.run(detIn, detOut);
            detRuns++;
            for (int[] b : boxesFromProb(detOutF)) {
                if ((b[1] < TILE_EDGE && y > 0) || (b[3] > detH - TILE_EDGE && y + detH < rh)) continue;
                boxes.add(new int[]{(int) (b[0] / sc), (int) ((b[1] + y) / sc), (int) (b[2] / sc), (int) ((b[3] + y) / sc)});
            }
        }
        return boxes;
    }

    /** Connected components of the thresholded probability map, scored and expanded like PP-OCR's DB postprocess (axis-aligned). */
    private List<int[]> boxesFromProb(FloatBuffer prob) {
        int n = detH * detW;
        boolean[] seen = new boolean[n];
        ArrayDeque<Integer> q = new ArrayDeque<>();
        List<int[]> out = new ArrayList<>();
        for (int s = 0; s < n; s++) {
            if (seen[s] || prob.get(s) <= BIN_THRESHOLD) continue;
            int minX = detW, minY = detH, maxX = -1, maxY = -1, count = 0;
            double sum = 0;
            seen[s] = true; q.add(s);
            while (!q.isEmpty()) {
                int i = q.poll(), x = i % detW, y = i / detW;
                count++; sum += prob.get(i);
                minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= detW || ny >= detH) continue;
                    int j = ny * detW + nx;
                    if (!seen[j] && prob.get(j) > BIN_THRESHOLD) { seen[j] = true; q.add(j); }
                }
            }
            if (count < MIN_COMPONENT_PIXELS || sum / count < BOX_THRESHOLD) continue;
            float bw = maxX - minX + 1, bh = maxY - minY + 1;
            float d = bw * bh * UNCLIP_RATIO / (2 * (bw + bh));
            out.add(new int[]{Math.round(minX - d), Math.round(minY - d), Math.round(maxX + 1 + d), Math.round(maxY + 1 + d)});
        }
        return out;
    }

    /** Cut lines wider than the recognizer holds at the emptiest column (a gap between glyphs). */
    private List<int[]> splitWide(int[] argb, int w, int x0, int y0, int x1, int y1) {
        int cw = (y1 - y0) * recW / recH, width = x1 - x0;
        List<int[]> segs = new ArrayList<>();
        if (width <= cw) { segs.add(new int[]{x0, x1}); return segs; }
        int[] gray = new int[width * (y1 - y0)];
        for (int y = y0, k = 0; y < y1; y++) for (int x = x0; x < x1; x++) {
            int p = argb[y * w + x];
            gray[k++] = (299 * ((p >> 16) & 0xff) + 587 * ((p >> 8) & 0xff) + 114 * (p & 0xff)) / 1000;
        }
        int[] sorted = gray.clone(); Arrays.sort(sorted);
        int med = sorted[sorted.length / 2];
        long[] ink = new long[width];
        for (int k = 0; k < gray.length; k++) ink[k % width] += Math.abs(gray[k] - med);
        int prev = 0;
        while (width - prev > cw) {
            int lo = prev + (int) (cw * .6), hi = prev + cw, best = lo;
            for (int c = lo; c < hi; c++) if (ink[c] < ink[best]) best = c;
            segs.add(new int[]{x0 + prev, x0 + best});
            prev = best;
        }
        segs.add(new int[]{x0 + prev, x1});
        return segs;
    }

    private Object[] recognize(int[] argb, int w, int cx, int cy, int cw, int ch) {
        int nw = Math.min(recW, Math.max(1, Math.round((float) cw * recH / ch)));
        int[] px = resize(argb, w, cx, cy, cw, ch, nw, recH);
        FloatBuffer in = recInF;
        int plane = recH * recW;
        for (int i = 0; i < 3 * plane; i++) in.put(i, 0f);
        for (int y = 0; y < recH; y++) for (int x = 0; x < nw; x++) {
            int p = px[y * nw + x], i = y * recW + x;
            // Same channel order as the benchmarked pipeline (BGR).
            in.put(i, (p & 0xff) / 127.5f - 1f);
            in.put(plane + i, ((p >> 8) & 0xff) / 127.5f - 1f);
            in.put(2 * plane + i, ((p >> 16) & 0xff) / 127.5f - 1f);
        }
        recIn.rewind(); recOut.rewind();
        rec.run(recIn, recOut);
        recRuns++;
        FloatBuffer o = recOutF;
        StringBuilder s = new StringBuilder();
        float confSum = 0; int kept = 0, prev = 0;
        for (int t = 0; t < steps; t++) {
            int best = 0; float bv = -Float.MAX_VALUE;
            for (int c = 0; c < classes; c++) { float v = o.get(t * classes + c); if (v > bv) { bv = v; best = c; } }
            if (best != prev && best != 0 && best < vocab.length) { s.append(vocab[best]); confSum += bv; kept++; }
            prev = best;
        }
        return new Object[]{s.toString(), kept == 0 ? 0f : confSum / kept};
    }

    /** Bilinear resize of a sub-rectangle with half-pixel centres (matches cv2.INTER_LINEAR). */
    static int[] resize(int[] src, int sw, int sx0, int sy0, int cw, int ch, int dw, int dh) {
        int[] out = new int[dw * dh];
        float fx = (float) cw / dw, fy = (float) ch / dh;
        for (int y = 0; y < dh; y++) {
            float sy = Math.max(0, (y + .5f) * fy - .5f);
            int y0 = Math.min((int) sy, ch - 1), y1 = Math.min(y0 + 1, ch - 1);
            float wy = sy - y0;
            for (int x = 0; x < dw; x++) {
                float sx = Math.max(0, (x + .5f) * fx - .5f);
                int x0 = Math.min((int) sx, cw - 1), x1 = Math.min(x0 + 1, cw - 1);
                float wx = sx - x0;
                int a = src[(sy0 + y0) * sw + sx0 + x0], b = src[(sy0 + y0) * sw + sx0 + x1];
                int c = src[(sy0 + y1) * sw + sx0 + x0], d = src[(sy0 + y1) * sw + sx0 + x1];
                int r = 0xff000000;
                for (int sh = 0; sh <= 16; sh += 8) {
                    float top = ((a >> sh) & 0xff) * (1 - wx) + ((b >> sh) & 0xff) * wx;
                    float bot = ((c >> sh) & 0xff) * (1 - wx) + ((d >> sh) & 0xff) * wx;
                    r |= (Math.round(top * (1 - wy) + bot * wy) & 0xff) << sh;
                }
                out[y * dw + x] = r;
            }
        }
        return out;
    }

    @Override public void close() { det.close(); rec.close(); }
}
