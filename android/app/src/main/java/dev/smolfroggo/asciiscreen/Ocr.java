package dev.smolfroggo.asciiscreen;

import android.content.Context;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;

/**
 * PP-OCRv6 small (official PaddlePaddle ONNX export) on ONNX Runtime. Both models take any input size: the detector
 * runs on exactly the image it is given (full screen in either orientation, or a small atlas of changed regions), and
 * text lines are recognised at their natural width, several per call.
 */
final class Ocr implements AutoCloseable, Pipeline.Reader {
    record Line(String text, float conf, int x0, int y0, int x1, int y1) {}

    private static final float[] MEAN = {0.485f, 0.456f, 0.406f};
    private static final float[] STD = {0.229f, 0.224f, 0.225f};
    /** The screen's short side is scaled to this many detector pixels (the scale the models were benchmarked at). */
    private static final int DET_SHORT = 608;
    private static final int REC_H = 48, REC_MAX_W = 1280, REC_BATCH = 8;
    private static final float BIN_THRESHOLD = 0.3f;
    private static final float BOX_THRESHOLD = 0.6f;
    private static final float UNCLIP_RATIO = 1.5f;
    private static final int MIN_COMPONENT_PIXELS = 6;

    private final OrtEnvironment env = OrtEnvironment.getEnvironment();
    private final OrtSession det, rec;
    private final String detName, recName;
    private final String[] vocab;
    private FloatBuffer buf = FloatBuffer.allocate(0);

    Ocr(Context ctx, int threads) throws IOException {
        try (OrtSession.SessionOptions o = new OrtSession.SessionOptions()) {
            o.setIntraOpNumThreads(threads);
            o.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
            det = env.createSession(asset(ctx, "v6_small_det.onnx"), o);
            rec = env.createSession(asset(ctx, "v6_small_rec.onnx"), o);
            detName = det.getInputNames().iterator().next();
            recName = rec.getInputNames().iterator().next();
        } catch (OrtException e) {
            throw new IOException(e);
        }
        List<String> chars = new ArrayList<>();
        chars.add("");
        try (BufferedReader r = new BufferedReader(new InputStreamReader(ctx.getAssets().open("v6_small_dict.txt"), StandardCharsets.UTF_8))) {
            for (String l; (l = r.readLine()) != null; ) chars.add(l);
        }
        chars.add(" ");
        vocab = chars.toArray(new String[0]);
    }

    private static byte[] asset(Context ctx, String name) throws IOException {
        try (InputStream in = ctx.getAssets().open(name)) { return in.readAllBytes(); }
    }

    /** A reusable direct buffer of exactly n floats, as ONNX Runtime wraps it without copying. */
    private FloatBuffer floats(int n) {
        if (buf.capacity() < n) buf = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        buf.clear();
        buf.limit(n);
        return buf;
    }

    int detRuns, recRuns;
    long resizeNs, detPrepNs, detNs, detPostNs, recPrepNs, recNs;

    void resetStats() { detRuns = 0; recRuns = 0; resizeNs = detPrepNs = detNs = detPostNs = recPrepNs = recNs = 0; }

    @Override public List<int[]> detect(List<Pipeline.Region> regions) {
        Pipeline.Region f = regions.get(0);
        int[] r0 = f.rect();
        float sc = (float) DET_SHORT / Math.min(f.w(), f.h());
        if (regions.size() > 1 || r0[0] != 0 || r0[1] != 0 || r0[2] != f.w() || r0[3] != f.h()) return detectAtlas(regions, f.w(), sc);
        List<int[]> out = new ArrayList<>();
        for (int[] b : runDet(f.px(), f.w(), f.h(), sc)) out.add(new int[]{b[0], b[1], b[2], b[3], 0});
        return out;
    }

    /**
     * Packs the regions into one image as wide as the screen, detects once over it at the screen's scale and maps each
     * box back into the region its centre falls in, clipped to that region.
     */
    private List<int[]> detectAtlas(List<Pipeline.Region> regions, int w, float sc) {
        final int gap = 12;
        List<int[]> rects = new ArrayList<>();
        for (Pipeline.Region g : regions) rects.add(g.rect());
        Integer[] order = new Integer[rects.size()];
        for (int i = 0; i < order.length; i++) order[i] = i;
        Arrays.sort(order, (a, b) -> Integer.compare(rects.get(b)[3] - rects.get(b)[1], rects.get(a)[3] - rects.get(a)[1]));
        int aw = w + 2 * gap, x = gap, y = gap, rowH = 0;
        int[][] at = new int[rects.size()][];
        for (int i : order) {
            int[] r = rects.get(i);
            int rw = r[2] - r[0], rh = r[3] - r[1];
            if (x + rw + gap > aw) { x = gap; y += rowH + gap; rowH = 0; }
            at[i] = new int[]{x, y};
            x += rw + gap; rowH = Math.max(rowH, rh);
        }
        int ah = y + rowH + gap;
        int[] atlas = new int[aw * ah];
        Arrays.fill(atlas, 0xffffffff);
        for (int i = 0; i < at.length; i++) {
            int[] r = rects.get(i);
            int[] argb = regions.get(i).px();
            for (int row = r[1]; row < r[3]; row++) System.arraycopy(argb, row * w + r[0], atlas, (at[i][1] + row - r[1]) * aw + at[i][0], r[2] - r[0]);
        }
        List<int[]> out = new ArrayList<>();
        for (int[] b : runDet(atlas, aw, ah, sc)) {
            int cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
            for (int i = 0; i < at.length; i++) {
                int[] r = rects.get(i);
                int ox = at[i][0], oy = at[i][1], rw = r[2] - r[0], rh = r[3] - r[1];
                if (cx < ox || cx >= ox + rw || cy < oy || cy >= oy + rh) continue;
                out.add(new int[]{r[0] + Math.max(0, b[0] - ox), r[1] + Math.max(0, b[1] - oy),
                        r[0] + Math.min(rw, b[2] - ox), r[1] + Math.min(rh, b[3] - oy), i});
                break;
            }
        }
        return out;
    }

    /** One detector pass over the whole image, scaled by sc and padded to a multiple of 32. Boxes in image pixels. */
    private List<int[]> runDet(int[] img, int iw, int ih, float sc) {
        int rw = Math.max(1, Math.round(iw * sc)), rh = Math.max(1, Math.round(ih * sc));
        int pw = (rw + 31) / 32 * 32, ph = (rh + 31) / 32 * 32, plane = pw * ph;
        long t = System.nanoTime();
        int[] rs = resize(img, iw, 0, 0, iw, ih, rw, rh);
        long t0 = System.nanoTime();
        resizeNs += t0 - t;
        FloatBuffer in = floats(3 * plane);
        for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) {
            int p = y < rh && x < rw ? rs[y * rw + x] : 0xff000000, i = y * pw + x;
            in.put(i, (((p >> 16) & 0xff) / 255f - MEAN[0]) / STD[0]);
            in.put(plane + i, (((p >> 8) & 0xff) / 255f - MEAN[1]) / STD[1]);
            in.put(2 * plane + i, ((p & 0xff) / 255f - MEAN[2]) / STD[2]);
        }
        List<int[]> boxes = new ArrayList<>();
        try (OnnxTensor x = OnnxTensor.createTensor(env, in, new long[]{1, 3, ph, pw})) {
            long t1 = System.nanoTime();
            try (OrtSession.Result r = det.run(Map.of(detName, x))) {
                long t2 = System.nanoTime();
                detRuns++;
                List<int[]> found = boxesFromProb(((OnnxTensor) r.get(0)).getFloatBuffer(), pw, ph);
                detPrepNs += t1 - t0; detNs += t2 - t1; detPostNs += System.nanoTime() - t2;
                for (int[] b : found) {
                    boxes.add(new int[]{Math.max(0, (int) (b[0] / sc)), Math.max(0, (int) (b[1] / sc)),
                            Math.min(iw, (int) Math.ceil(b[2] / sc)), Math.min(ih, (int) Math.ceil(b[3] / sc))});
                }
            }
        } catch (OrtException e) {
            throw new IllegalStateException(e);
        }
        return boxes;
    }

    /** Connected components of the thresholded probability map, scored and expanded like PP-OCR's DB postprocess (axis-aligned). */
    private static List<int[]> boxesFromProb(FloatBuffer prob, int detW, int detH) {
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

    /**
     * Recognise each box (null where it reads blank), in the same order. Lines wider than the recogniser's limit are cut
     * at glyph gaps; the pieces are sorted by width and run in batches of similar width.
     */
    @Override public List<Line> recognize(List<Pipeline.Region> boxes) {
        List<int[]> segs = new ArrayList<>(); // {box index, x0, y0, x1, y1, natural width}
        for (int k = 0; k < boxes.size(); k++) {
            Pipeline.Region c = boxes.get(k);
            int[] argb = c.px(), b = c.rect();
            int w = c.w(), h = c.h();
            int x0 = Math.max(0, b[0]), y0 = Math.max(0, b[1]), x1 = Math.min(w, b[2]), y1 = Math.min(h, b[3]);
            if (x1 - x0 < 3 || y1 - y0 < 3) continue;
            for (int[] s : splitWide(argb, w, x0, y0, x1, y1)) {
                int nw = Math.min(REC_MAX_W, Math.max(8, Math.round((float) (s[1] - s[0]) * REC_H / (y1 - y0))));
                segs.add(new int[]{k, s[0], y0, s[1], y1, nw});
            }
        }
        String[] text = new String[segs.size()];
        float[] conf = new float[segs.size()];
        Integer[] order = new Integer[segs.size()];
        for (int i = 0; i < order.length; i++) order[i] = i;
        Arrays.sort(order, (p, q) -> Integer.compare(segs.get(p)[5], segs.get(q)[5]));
        for (int i = 0; i < order.length; ) {
            int j = i + 1, first = segs.get(order[i])[5];
            while (j < order.length && j - i < REC_BATCH && segs.get(order[j])[5] <= first * 3 / 2 + 32) j++;
            runRec(boxes, segs, Arrays.copyOfRange(order, i, j), text, conf);
            i = j;
        }
        StringBuilder[] sb = new StringBuilder[boxes.size()];
        float[] cs = new float[boxes.size()];
        int[] cn = new int[boxes.size()];
        for (int i = 0; i < segs.size(); i++) {
            int k = segs.get(i)[0];
            if (sb[k] == null) sb[k] = new StringBuilder();
            sb[k].append(text[i]); cs[k] += conf[i]; cn[k]++;
        }
        List<Line> out = new ArrayList<>(Collections.nCopies(boxes.size(), (Line) null));
        for (int k = 0; k < boxes.size(); k++) {
            if (sb[k] == null || sb[k].toString().isBlank()) continue;
            int[] s = null;
            for (int[] g : segs) if (g[0] == k) { s = s == null ? g.clone() : s; s[3] = Math.max(s[3], g[3]); }
            out.set(k, new Line(sb[k].toString(), cs[k] / cn[k], s[1], s[2], s[3], s[4]));
        }
        return out;
    }

    private void runRec(List<Pipeline.Region> crops, List<int[]> segs, Integer[] batch, String[] text, float[] conf) {
        long t0 = System.nanoTime();
        int bw = 0;
        for (int i : batch) bw = Math.max(bw, segs.get(i)[5]);
        bw = (bw + 7) / 8 * 8;
        int plane = REC_H * bw, n = batch.length;
        FloatBuffer in = floats(3 * plane * n);
        for (int i = 0; i < 3 * plane * n; i++) in.put(i, 0f);
        for (int b = 0; b < n; b++) {
            int[] s = segs.get(batch[b]);
            int nw = s[5], base = b * 3 * plane;
            Pipeline.Region c = crops.get(s[0]);
            int[] px = resize(c.px(), c.w(), s[1], s[2], s[3] - s[1], s[4] - s[2], nw, REC_H);
            for (int y = 0; y < REC_H; y++) for (int x = 0; x < nw; x++) {
                int p = px[y * nw + x], i = base + y * bw + x;
                // Same channel order as the benchmarked pipeline (BGR).
                in.put(i, (p & 0xff) / 127.5f - 1f);
                in.put(plane + i, ((p >> 8) & 0xff) / 127.5f - 1f);
                in.put(2 * plane + i, ((p >> 16) & 0xff) / 127.5f - 1f);
            }
        }
        try (OnnxTensor x = OnnxTensor.createTensor(env, in, new long[]{n, 3, REC_H, bw})) {
            long t1 = System.nanoTime();
            try (OrtSession.Result r = rec.run(Map.of(recName, x))) {
                recRuns++;
                recPrepNs += t1 - t0; recNs += System.nanoTime() - t1;
                OnnxTensor o = (OnnxTensor) r.get(0);
                long[] shape = o.getInfo().getShape();
                int steps = (int) shape[1], classes = (int) shape[2];
                FloatBuffer f = o.getFloatBuffer();
                for (int b = 0; b < n; b++) {
                    int used = Math.min(steps, (segs.get(batch[b])[5] + 7) / 8);
                    StringBuilder s = new StringBuilder();
                    float cs = 0; int kept = 0, prev = 0, base = b * steps * classes;
                    for (int t = 0; t < used; t++) {
                        int best = 0; float bv = -Float.MAX_VALUE;
                        for (int c = 0; c < classes; c++) { float v = f.get(base + t * classes + c); if (v > bv) { bv = v; best = c; } }
                        if (best != prev && best != 0 && best < vocab.length) { s.append(vocab[best]); cs += bv; kept++; }
                        prev = best;
                    }
                    text[batch[b]] = s.toString();
                    conf[batch[b]] = kept == 0 ? 0f : cs / kept;
                }
            }
        } catch (OrtException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Cut lines wider than the recogniser's limit at the emptiest column (a gap between glyphs). */
    private static List<int[]> splitWide(int[] argb, int w, int x0, int y0, int x1, int y1) {
        int cw = (y1 - y0) * REC_MAX_W / REC_H, width = x1 - x0;
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

    @Override public void close() {
        try { det.close(); rec.close(); } catch (OrtException e) { throw new IllegalStateException(e); }
    }
}
