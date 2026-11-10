package dev.smolfroggo.asciiscreen;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Keeps the text read so far and only reads the parts of the screen that changed since the previous frame
 * (port of macos/Sources/ascii-screen/Pipeline.swift). A change that lies inside a line already read is
 * re-recognised without running the detector; other changes are packed into one image for a single detector pass.
 */
final class Pipeline {
    interface Reader {
        /** Line boxes {x0,y0,x1,y1} found inside pixel rects {x0,y0,x1,y1}; null rects means the whole frame. */
        List<int[]> detect(int[] px, int w, int h, List<int[]> rects);
        /** The text in each box, in order, null where it is blank; all boxes in as few model calls as possible. */
        List<Ocr.Line> recognize(int[] px, int w, int h, List<int[]> boxes);
    }

    static final int TILE = 32;
    static final int FULL_EVERY = 30;

    private final Reader reader;
    private int[] prev;
    private int pw, ph, sinceFull;
    private List<Ocr.Line> lines = new ArrayList<>();
    private int[] reference;

    /** Stats for the last processed frame. */
    String mode = "";
    int regions, rereads, scrollDy, moved;
    float areaPct;
    List<int[]> lastRects = List.of();

    Pipeline(Reader reader) { this.reader = reader; }

    List<Ocr.Line> lines() { return lines; }

    /** Returns false when the frame is pixel-identical to the previous one. */
    boolean process(int[] px, int w, int h) {
        regions = 0; rereads = 0; areaPct = 0; scrollDy = 0; moved = 0; lastRects = List.of();
        if (prev == null || pw != w || ph != h || sinceFull >= FULL_EVERY) return full(px, w, h);
        Integer dy = scrollShift(prev, px, w, h);
        List<int[][]> dirty;
        if (dy != null) {
            scrollDy = dy;
            dirty = followScroll(dy, prev, px, w, h);
        } else {
            dirty = dirtyRegions(prev, px, w, h);
            if (dirty.isEmpty()) { mode = "unchanged"; return false; }
        }

        List<Ocr.Line> again = new ArrayList<>();
        List<int[]> rects = new ArrayList<>();
        for (int[][] d : dirty) {
            Ocr.Line inside = lineContaining(d[1]);
            if (inside != null) { if (!again.contains(inside)) again.add(inside); }
            else rects.add(trimAway(d[0], d[1]));
        }
        if (!rects.isEmpty()) {
            List<int[]> grown = expandOverText(rects, w, h);
            if (grown == null || area(grown) > 0.5 * w * h) return full(px, w, h);
            rects = grown;
            again.removeIf(l -> intersectsAny(l, grown));
        }

        List<Ocr.Line> next = new ArrayList<>(lines.size());
        for (Ocr.Line l : lines) if (!again.contains(l) && !intersectsAny(l, rects)) next.add(l);
        List<int[]> boxes = new ArrayList<>();
        for (Ocr.Line l : again) boxes.add(new int[]{l.x0(), l.y0(), l.x1(), l.y1()});
        if (!rects.isEmpty()) boxes.addAll(reader.detect(px, w, h, rects));
        if (!boxes.isEmpty()) for (Ocr.Line r : reader.recognize(px, w, h, boxes)) if (r != null) next.add(r);
        next.sort((a, b) -> a.y0() != b.y0() ? Integer.compare(a.y0(), b.y0()) : Integer.compare(a.x0(), b.x0()));
        lines = next;
        regions = rects.size();
        lastRects = rects;
        rereads = again.size();
        areaPct = 100f * area(rects) / ((float) w * h);
        mode = (dy != null ? "scroll+" : "") + (rects.isEmpty() ? (again.isEmpty() ? "moved" : "reread") : "regions");
        sinceFull++;
        prev = px;
        return true;
    }

    private boolean full(int[] px, int w, int h) {
        lines = new ArrayList<>();
        for (Ocr.Line l : reader.recognize(px, w, h, reader.detect(px, w, h, null))) if (l != null) lines.add(l);
        prev = px; pw = w; ph = h; sinceFull = 0;
        mode = "full"; areaPct = 100;
        return true;
    }

    /**
     * Cut the padding back off cached lines that the changed pixels don't touch, so a change beside unchanged text (a
     * scrollbar, a caret) doesn't make that text be read again.
     */
    private int[] trimAway(int[] padded, int[] e) {
        int[] r = padded.clone();
        for (Ocr.Line l : lines) {
            // Same 2 px slack as expandOverText, so a trimmed edge is not grown back over the line.
            int x0 = l.x0() - 2, y0 = l.y0() - 2, x1 = l.x1() + 2, y1 = l.y1() + 2;
            if (x0 >= r[2] || x1 <= r[0] || y0 >= r[3] || y1 <= r[1]) continue;
            if (x0 < e[2] && x1 > e[0] && y0 < e[3] && y1 > e[1]) continue;
            if (x1 <= e[0]) r[0] = Math.max(r[0], x1);
            else if (x0 >= e[2]) r[2] = Math.min(r[2], x0);
            else if (y1 <= e[1]) r[1] = Math.max(r[1], y1);
            else r[3] = Math.min(r[3], y0);
        }
        return r;
    }

    /** A cached line whose box (with 2 px slack) holds every changed pixel of a region. */
    private Ocr.Line lineContaining(int[] e) {
        for (Ocr.Line l : lines) {
            if (e[0] >= l.x0() - 2 && e[1] >= l.y0() - 2 && e[2] <= l.x1() + 2 && e[3] <= l.y1() + 2) return l;
        }
        return null;
    }

    /**
     * 8-connected groups of changed 32 px tiles. Each entry is {padded rect, exact bounds of the changed pixels},
     * as {x0,y0,x1,y1}; padding lets text that spills out of the change be re-read whole.
     */
    static List<int[][]> dirtyRegions(int[] a, int[] b, int w, int h) {
        int T = TILE, cols = (w + T - 1) / T, rows = (h + T - 1) / T;
        int[] minX = new int[cols * rows], maxX = new int[cols * rows], minY = new int[cols * rows], maxY = new int[cols * rows];
        boolean[] dirty = new boolean[cols * rows];
        for (int y = 0; y < h; y++) {
            int r = y * w;
            if (Arrays.equals(a, r, r + w, b, r, r + w)) continue;
            int ty = y / T;
            for (int tx = 0; tx < cols; tx++) {
                int x0 = tx * T, x1 = Math.min(w, x0 + T);
                int m = Arrays.mismatch(a, r + x0, r + x1, b, r + x0, r + x1);
                if (m < 0) continue;
                int last = x1 - 1;
                while (a[r + last] == b[r + last]) last--;
                int i = ty * cols + tx;
                if (!dirty[i]) { dirty[i] = true; minX[i] = x0 + m; maxX[i] = last; minY[i] = y; maxY[i] = y; }
                else { minX[i] = Math.min(minX[i], x0 + m); maxX[i] = Math.max(maxX[i], last); maxY[i] = y; }
            }
        }
        List<int[][]> out = new ArrayList<>();
        boolean[] seen = new boolean[dirty.length];
        int[] stack = new int[dirty.length];
        for (int s = 0; s < dirty.length; s++) {
            if (!dirty[s] || seen[s]) continue;
            int sp = 0, tx0 = cols, ty0 = rows, tx1 = 0, ty1 = 0;
            int ex0 = w, ey0 = h, ex1 = 0, ey1 = 0;
            stack[sp++] = s; seen[s] = true;
            while (sp > 0) {
                int i = stack[--sp], x = i % cols, y = i / cols;
                tx0 = Math.min(tx0, x); tx1 = Math.max(tx1, x); ty0 = Math.min(ty0, y); ty1 = Math.max(ty1, y);
                ex0 = Math.min(ex0, minX[i]); ex1 = Math.max(ex1, maxX[i] + 1); ey0 = Math.min(ey0, minY[i]); ey1 = Math.max(ey1, maxY[i] + 1);
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
                    int j = ny * cols + nx;
                    if (dirty[j] && !seen[j]) { seen[j] = true; stack[sp++] = j; }
                }
            }
            int[] padded = {Math.max(0, tx0 * T - 2 * T), Math.max(0, ty0 * T - T / 2),
                    Math.min(w, (tx1 + 3) * T), Math.min(h, (ty1 + 1) * T + T / 2)};
            out.add(new int[][]{padded, {ex0, ey0, ex1, ey1}});
        }
        return out;
    }

    /**
     * Vertical scroll between frames: the shift dy such that new row y shows old row y+dy, found by matching 128 px row
     * slices of what changed. Null when the change doesn't look like a scroll.
     */
    static Integer scrollShift(int[] a, int[] b, int w, int h) {
        final int S = 128;
        int y0 = h, y1 = 0;
        for (int y = 0; y < h; y++) if (!Arrays.equals(a, y * w, y * w + w, b, y * w, y * w + w)) { y0 = Math.min(y0, y); y1 = y + 1; }
        if (y1 - y0 < 16) return null;
        Map<Integer, Integer> votes = new HashMap<>();
        int changed = 0;
        for (int x0 = 0; x0 < w; x0 += S) {
            int n = Math.min(S, w - x0);
            if (n <= 1) continue;
            Map<Long, Integer> rowOf = new HashMap<>(); // slice hash -> old row, -1 if it repeats
            for (int y = y0; y < y1; y++) {
                Long k = sliceKey(a, y * w + x0, n);
                if (k != null) rowOf.merge(k, y, (o, v) -> -1);
            }
            for (int y = y0; y < y1; y++) {
                int o = y * w + x0;
                if (Arrays.equals(a, o, o + n, b, o, o + n)) continue;
                Long k = sliceKey(b, o, n);
                if (k == null) continue;
                changed++;
                Integer oy = rowOf.get(k);
                if (oy != null && oy >= 0) votes.merge(oy - y, 1, Integer::sum);
            }
        }
        Map.Entry<Integer, Integer> best = null;
        for (Map.Entry<Integer, Integer> e : votes.entrySet()) if (best == null || e.getValue() > best.getValue()) best = e;
        if (best == null || best.getValue() < 16 || best.getValue() * 4 < changed) return null;
        return best.getKey();
    }

    /** Plain-colour slices match anywhere, so they don't vote. */
    private static Long sliceKey(int[] p, int o, int n) {
        boolean plain = true;
        long k = 1125899906842597L;
        for (int i = 0; i < n; i++) { plain &= p[o + i] == p[o]; k = 31 * k + p[o + i]; }
        return plain ? null : k;
    }

    /**
     * After a scroll by dy, move cached lines along with the page and return only what really needs reading: newly
     * revealed rows and anything that changed on top of the scroll.
     */
    private List<int[][]> followScroll(int dy, int[] a, int[] b, int w, int h) {
        final int T = TILE;
        if (reference == null || reference.length != w * h) reference = new int[w * h];
        int[] ref = reference;
        // The old frame, with every tile row that matches its scrolled source swapped for that source.
        for (int y = 0; y < h; y++) {
            int r = y * w, sy = y + dy;
            System.arraycopy(a, r, ref, r, w);
            if (sy < 0 || sy >= h || Arrays.equals(a, r, r + w, b, r, r + w)) continue;
            for (int x0 = 0; x0 < w; x0 += T) {
                int n = Math.min(T, w - x0), s = sy * w + x0;
                if (Arrays.equals(a, s, s + n, b, r + x0, r + x0 + n)) System.arraycopy(a, s, ref, r + x0, n);
            }
        }
        List<int[][]> dirty = dirtyRegions(ref, b, w, h);
        List<Ocr.Line> next = new ArrayList<>(lines.size());
        for (Ocr.Line l : lines) {
            if (same(a, b, w, h, l.x0(), l.y0(), l.x1(), l.y1(), 0)) { next.add(l); continue; }
            int my0 = l.y0() - dy, my1 = l.y1() - dy;
            if (my0 >= 0 && my1 <= h && same(a, b, w, h, l.x0(), my0, l.x1(), my1, dy)) {
                next.add(new Ocr.Line(l.text(), l.conf(), l.x0(), my0, l.x1(), my1));
                moved++;
                continue;
            }
            // Text that only partly survived the scroll (cut by the window edge, or half revealed) is read again where it
            // now sits, skipping rows that didn't change, like a toolbar it slid under.
            int[] r = changedRows(a, b, w, h, l.x0(), my0, l.x1(), my1);
            if (r != null) dirty.add(new int[][]{r, r});
        }
        lines = next;
        return dirty;
    }

    /** New rows y0..y1 at x0..x1 equal old rows y0+shift..y1+shift. */
    private static boolean same(int[] a, int[] b, int w, int h, int x0, int y0, int x1, int y1, int shift) {
        x0 = Math.max(0, x0); x1 = Math.min(w, x1); y0 = Math.max(0, y0); y1 = Math.min(h, y1);
        if (x1 <= x0 || y1 <= y0) return false;
        for (int y = y0; y < y1; y++) {
            int sy = y + shift;
            if (sy < 0 || sy >= h || !Arrays.equals(b, y * w + x0, y * w + x1, a, sy * w + x0, sy * w + x1)) return false;
        }
        return true;
    }

    private static int[] changedRows(int[] a, int[] b, int w, int h, int x0, int y0, int x1, int y1) {
        x0 = Math.max(0, x0); x1 = Math.min(w, x1); y0 = Math.max(0, y0); y1 = Math.min(h, y1);
        int lo = -1, hi = -1;
        for (int y = y0; y < y1; y++) {
            if (!Arrays.equals(a, y * w + x0, y * w + x1, b, y * w + x0, y * w + x1)) { if (lo < 0) lo = y; hi = y; }
        }
        return lo < 0 ? null : new int[]{x0, lo, x1, hi + 1};
    }

    /** Grow rects until no cached line straddles an edge, then merge overlaps; null (read everything) if it doesn't settle. */
    List<int[]> expandOverText(List<int[]> input, int w, int h) {
        List<int[]> rects = new ArrayList<>();
        for (int[] r : input) rects.add(r.clone());
        for (int pass = 0; ; pass++) {
            if (pass > 64) return null;
            boolean changed = false;
            for (int[] r : rects) for (Ocr.Line l : lines) {
                int bx0 = Math.max(0, l.x0() - 2), by0 = Math.max(0, l.y0() - 2), bx1 = Math.min(w, l.x1() + 2), by1 = Math.min(h, l.y1() + 2);
                boolean meets = bx0 < r[2] && bx1 > r[0] && by0 < r[3] && by1 > r[1];
                boolean inside = bx0 >= r[0] && by0 >= r[1] && bx1 <= r[2] && by1 <= r[3];
                if (meets && !inside) {
                    r[0] = Math.min(r[0], bx0); r[1] = Math.min(r[1], by0); r[2] = Math.max(r[2], bx1); r[3] = Math.max(r[3], by1);
                    changed = true;
                }
            }
            List<int[]> merged = new ArrayList<>();
            for (int[] r : rects) {
                int[] m = null;
                for (int[] q : merged) if (q[0] < r[2] && q[2] > r[0] && q[1] < r[3] && q[3] > r[1]) { m = q; break; }
                if (m == null) merged.add(r);
                else { m[0] = Math.min(m[0], r[0]); m[1] = Math.min(m[1], r[1]); m[2] = Math.max(m[2], r[2]); m[3] = Math.max(m[3], r[3]); changed = true; }
            }
            rects = merged;
            if (!changed) return rects;
        }
    }

    private static boolean intersectsAny(Ocr.Line l, List<int[]> rects) {
        for (int[] r : rects) if (l.x0() < r[2] && l.x1() > r[0] && l.y0() < r[3] && l.y1() > r[1]) return true;
        return false;
    }

    private static long area(List<int[]> rects) {
        long a = 0;
        for (int[] r : rects) a += (long) (r[2] - r[0]) * (r[3] - r[1]);
        return a;
    }
}
