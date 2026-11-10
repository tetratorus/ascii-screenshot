package dev.smolfroggo.asciiscreen;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Arrays;

/**
 * The 32 px tiles of a frame that differ from the previous frame, so a waiting frame costs only what changed. A patch
 * against no previous frame (or one of a different size, e.g. after rotation) holds the whole frame.
 */
final class FramePatch {
    static final int T = 32;
    final int w, h;
    /** Indices of changed tiles (row-major), or null when data is the whole frame. */
    final int[] tiles;
    /** Pixels of each changed tile in order, each tile row-major at its clipped size. */
    final int[] data;

    private FramePatch(int w, int h, int[] tiles, int[] data) { this.w = w; this.h = h; this.tiles = tiles; this.data = data; }

    /** Null if cur equals prev. */
    static FramePatch diff(int[] prev, int pw, int ph, int[] cur, int w, int h) {
        if (prev == null || pw != w || ph != h) return new FramePatch(w, h, null, cur.clone());
        int cols = (w + T - 1) / T, rows = (h + T - 1) / T;
        int[] idx = new int[cols * rows];
        int n = 0, size = 0;
        for (int ty = 0; ty < rows; ty++) for (int tx = 0; tx < cols; tx++) {
            int x0 = tx * T, x1 = Math.min(w, x0 + T), y1 = Math.min(h, ty * T + T);
            for (int y = ty * T; y < y1; y++) {
                int o = y * w;
                if (!Arrays.equals(prev, o + x0, o + x1, cur, o + x0, o + x1)) {
                    idx[n++] = ty * cols + tx;
                    size += (x1 - x0) * (y1 - ty * T);
                    break;
                }
            }
        }
        if (n == 0) return null;
        int[] data = new int[size];
        int k = 0;
        for (int i = 0; i < n; i++) {
            int tx = idx[i] % cols, ty = idx[i] / cols, x0 = tx * T, tw = Math.min(w, x0 + T) - x0;
            for (int y = ty * T, y1 = Math.min(h, y + T); y < y1; y++, k += tw) System.arraycopy(cur, y * w + x0, data, k, tw);
        }
        return new FramePatch(w, h, Arrays.copyOf(idx, n), data);
    }

    /** The frame: base (the previous frame, left untouched) with this patch applied. */
    int[] apply(int[] base) {
        if (tiles == null) return data.clone();
        if (base == null || base.length != w * h) throw new IllegalStateException("patch needs a " + w + "x" + h + " base");
        int[] out = base.clone();
        int cols = (w + T - 1) / T, k = 0;
        for (int t : tiles) {
            int tx = t % cols, ty = t / cols, x0 = tx * T, tw = Math.min(w, x0 + T) - x0;
            for (int y = ty * T, y1 = Math.min(h, y + T); y < y1; y++, k += tw) System.arraycopy(data, k, out, y * w + x0, tw);
        }
        return out;
    }

    int changedTiles() { return tiles == null ? -1 : tiles.length; }

    long bytes() { return 4L * data.length + (tiles == null ? 0 : 4L * tiles.length); }

    void write(DataOutputStream out) throws IOException {
        out.writeInt(w); out.writeInt(h);
        out.writeInt(tiles == null ? -1 : tiles.length);
        if (tiles != null) out.write(ints(tiles));
        out.writeInt(data.length);
        out.write(ints(data));
    }

    static FramePatch read(DataInputStream in) throws IOException {
        int w = in.readInt(), h = in.readInt(), nt = in.readInt();
        int[] tiles = nt < 0 ? null : readInts(in, nt);
        return new FramePatch(w, h, tiles, readInts(in, in.readInt()));
    }

    private static byte[] ints(int[] a) {
        ByteBuffer b = ByteBuffer.allocate(a.length * 4);
        b.asIntBuffer().put(a);
        return b.array();
    }

    private static int[] readInts(DataInputStream in, int n) throws IOException {
        byte[] b = new byte[n * 4];
        in.readFully(b);
        int[] a = new int[n];
        ByteBuffer.wrap(b).asIntBuffer().get(a);
        return a;
    }
}
