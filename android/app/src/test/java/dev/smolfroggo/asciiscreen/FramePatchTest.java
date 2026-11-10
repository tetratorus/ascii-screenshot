package dev.smolfroggo.asciiscreen;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import org.junit.Test;

public class FramePatchTest {
    static int[] noise(Random r, int n) { int[] a = new int[n]; for (int i = 0; i < n; i++) a[i] = r.nextInt(); return a; }

    @Test public void unchangedIsNull() {
        int[] a = noise(new Random(1), 100 * 70);
        assertNull(FramePatch.diff(a, 100, 70, a.clone(), 100, 70));
    }

    @Test public void sizeChangeIsWholeFrame() {
        int[] a = noise(new Random(2), 100 * 70), b = noise(new Random(3), 70 * 100);
        FramePatch p = FramePatch.diff(a, 100, 70, b, 70, 100);
        assertEquals(-1, p.changedTiles());
        assertArrayEquals(b, p.apply(a));
    }

    /** A long chain of patches, some round-tripped through the spill format, rebuilds every frame exactly. */
    @Test public void chainRebuildsEveryFrame() throws Exception {
        Random r = new Random(4);
        int w = 103, h = 77;
        List<int[]> frames = new ArrayList<>();
        int[] f = noise(r, w * h);
        frames.add(f);
        for (int i = 0; i < 40; i++) {
            f = f.clone();
            int x = r.nextInt(w), y = r.nextInt(h);
            for (int k = 0; k < 1 + r.nextInt(5); k++) f[Math.min(h - 1, y + k) * w + Math.min(w - 1, x + k * 7)] ^= 0x10101;
            frames.add(f);
        }
        int[] prev = null, rebuilt = null;
        for (int i = 0; i < frames.size(); i++) {
            FramePatch p = FramePatch.diff(prev, w, h, frames.get(i), w, h);
            if (i > 0) assertTrue(p.changedTiles() > 0 && p.bytes() < 4L * w * h);
            if (i % 3 == 0) {
                ByteArrayOutputStream bo = new ByteArrayOutputStream();
                p.write(new DataOutputStream(bo));
                p = FramePatch.read(new DataInputStream(new ByteArrayInputStream(bo.toByteArray())));
            }
            rebuilt = p.apply(rebuilt);
            assertArrayEquals("frame " + i, frames.get(i), rebuilt);
            prev = frames.get(i);
        }
    }
}
