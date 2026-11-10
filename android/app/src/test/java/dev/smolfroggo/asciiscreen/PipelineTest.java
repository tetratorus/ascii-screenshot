package dev.smolfroggo.asciiscreen;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.junit.Test;

public class PipelineTest {
    static final int W = 400, H = 800;

    /** Fake reader: every black-on-white "word" is a filled rect; text is its colour, read from the pixels. */
    static final class Fake implements Pipeline.Reader {
        final List<List<int[]>> reads = new ArrayList<>();
        final List<Ocr.Line> rereads = new ArrayList<>();
        final List<int[]> words = new ArrayList<>();

        @Override public List<Ocr.Line> read(int[] px, int w, int h, List<int[]> rects) {
            reads.add(rects);
            List<Ocr.Line> out = new ArrayList<>();
            for (int[] b : words) {
                boolean in = rects == null;
                if (rects != null) for (int[] r : rects) in |= b[0] >= r[0] && b[1] >= r[1] && b[2] <= r[2] && b[3] <= r[3];
                if (in) out.add(new Ocr.Line(Integer.toHexString(px[b[1] * w + b[0]]), 1, b[0], b[1], b[2], b[3]));
            }
            return out;
        }

        @Override public Ocr.Line reread(int[] px, int w, int h, Ocr.Line l) {
            rereads.add(l);
            return new Ocr.Line(Integer.toHexString(px[l.y0() * w + l.x0()]), 1, l.x0(), l.y0(), l.x1(), l.y1());
        }
    }

    static int[] blank() { int[] p = new int[W * H]; Arrays.fill(p, 0xffffffff); return p; }

    static void fill(int[] p, int[] b, int c) { for (int y = b[1]; y < b[3]; y++) for (int x = b[0]; x < b[2]; x++) p[y * W + x] = c; }

    static Fake screen(int[] p, int[]... words) {
        Fake f = new Fake();
        for (int[] b : words) { f.words.add(b); fill(p, b, 0xff000000); }
        return f;
    }

    @Test public void unchangedFrameIsNotRead() {
        int[] p = blank();
        Fake f = screen(p, new int[]{10, 10, 100, 30});
        Pipeline pl = new Pipeline(f);
        assertTrue(pl.process(p, W, H));
        assertFalse(pl.process(p.clone(), W, H));
        assertEquals(1, f.reads.size());
        assertNull(f.reads.get(0));
    }

    @Test public void changeInsideALineRereadsOnlyThatLine() {
        int[] p = blank();
        int[] a = {10, 10, 100, 30}, b = {10, 400, 100, 420};
        Fake f = screen(p, a, b);
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        int[] q = p.clone();
        fill(q, new int[]{20, 15, 40, 25}, 0xff111111);
        assertTrue(pl.process(q, W, H));
        assertEquals("reread", pl.mode);
        assertEquals(1, f.reads.size());
        assertEquals(1, f.rereads.size());
        assertEquals(a[1], f.rereads.get(0).y0());
        assertEquals(2, pl.lines().size());
    }

    @Test public void newTextReadsOnlyItsRegionAndKeepsTheRest() {
        int[] p = blank();
        int[] a = {10, 10, 100, 30};
        Fake f = screen(p, a);
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        int[] q = p.clone();
        int[] c = {200, 600, 300, 620};
        f.words.add(c);
        fill(q, c, 0xff000000);
        assertTrue(pl.process(q, W, H));
        assertEquals("regions", pl.mode);
        List<int[]> rects = f.reads.get(1);
        assertEquals(1, rects.size());
        int[] r = rects.get(0);
        assertTrue(r[0] <= c[0] && r[1] <= c[1] && r[2] >= c[2] && r[3] >= c[3]);
        assertTrue(r[3] <= a[1] || r[1] >= a[3]);
        assertEquals(2, pl.lines().size());
        assertTrue(pl.areaPct < 10);
    }

    @Test public void changeSpillingOutOfALineReadsTheWholeLine() {
        int[] p = blank();
        int[] a = {100, 100, 200, 120};
        Fake f = screen(p, a);
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        int[] q = p.clone();
        fill(q, new int[]{190, 100, 230, 120}, 0xff000000);
        f.words.set(0, new int[]{100, 100, 230, 120});
        pl.process(q, W, H);
        assertEquals("regions", pl.mode);
        int[] r = f.reads.get(1).get(0);
        assertTrue(r[0] <= 98 && r[2] >= 230);
        assertEquals(1, pl.lines().size());
        assertEquals(230, pl.lines().get(0).x1());
    }

    @Test public void bigChangeReadsEverything() {
        int[] p = blank();
        Fake f = screen(p, new int[]{10, 10, 100, 30});
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        int[] q = p.clone();
        fill(q, new int[]{0, 0, W, H * 2 / 3}, 0xff333333);
        pl.process(q, W, H);
        assertEquals("full", pl.mode);
        assertNull(f.reads.get(1));
    }

    @Test public void periodicFullRead() {
        int[] p = blank();
        Fake f = screen(p, new int[]{10, 10, 100, 30});
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        for (int i = 0; i < Pipeline.FULL_EVERY; i++) {
            p = p.clone();
            p[15 * W + 20] = 0xff000000 | (i + 1);
            pl.process(p, W, H);
            assertEquals("reread", pl.mode);
        }
        p = p.clone();
        p[15 * W + 20] = 0xff0000ff;
        pl.process(p, W, H);
        assertEquals("full", pl.mode);
    }

    static void texture(int[] p, int[] b, int seed) {
        for (int y = b[1]; y < b[3]; y++) for (int x = b[0]; x < b[2]; x++) p[y * W + x] = 0xff000000 | ((x * 31 + y * 17 + seed) * 2654435 & 0xffffff);
    }

    @Test public void scrollMovesCachedLinesAndReadsOnlyRevealedRows() {
        int[] p = blank();
        int[] header = {10, 10, 300, 30};
        int[][] words = {{10, 100, 300, 120}, {10, 300, 300, 320}, {10, 500, 300, 520}, {10, 700, 300, 720}};
        Fake f = new Fake();
        f.words.add(header); texture(p, header, 1);
        for (int[] b : words) { f.words.add(b); texture(p, b, b[1]); }
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        assertEquals(5, pl.lines().size());

        int dy = 40;
        int[] q = blank();
        System.arraycopy(p, 0, q, 0, 60 * W);
        for (int y = 60; y < H - dy; y++) System.arraycopy(p, (y + dy) * W, q, y * W, W);
        int[] fresh = {10, 770, 300, 790};
        texture(q, fresh, 99);
        f.words.clear();
        f.words.add(header);
        for (int[] b : words) f.words.add(new int[]{b[0], b[1] - dy, b[2], b[3] - dy});
        f.words.add(fresh);

        assertEquals(Integer.valueOf(dy), Pipeline.scrollShift(p, q, W, H));
        assertTrue(pl.process(q, W, H));
        assertEquals(dy, pl.scrollDy);
        assertEquals(4, pl.moved);
        assertEquals("scroll+regions", pl.mode);
        assertEquals(0, f.rereads.size());
        for (int[] r : f.reads.get(1)) assertTrue(r[1] >= 680);
        assertEquals(6, pl.lines().size());
        assertEquals(60, pl.lines().get(1).y0());
        assertEquals(790, pl.lines().get(5).y1());
    }

    @Test public void changeBesideALineDoesNotRereadIt() {
        int[] p = blank();
        int[] a = {10, 100, 360, 120};
        Fake f = screen(p, a);
        Pipeline pl = new Pipeline(f);
        pl.process(p, W, H);
        int[] q = p.clone();
        fill(q, new int[]{392, 80, 398, 200}, 0xff888888);
        pl.process(q, W, H);
        assertEquals("regions", pl.mode);
        for (int[] r : f.reads.get(1)) assertTrue(r[0] >= a[2]);
        assertEquals(1, pl.lines().size());
        assertEquals(0, f.rereads.size());
    }
}
