const { Jimp } = require('jimp');

// Mirrors detect_lines() in ascii_screenshot.py; keep constants and logic in sync.
const EDGE_THRESHOLD = 4; // include faint panel fills, not just high-contrast rules
const STRONG_EDGE_THRESHOLD = 10;
const MIN_LINE_FRAC = 0.025; // min line length as a fraction of image width/height
const EDGE_TOL_FRAC = 0.004; // merge tolerance as a fraction of image height
const FLAT_TOL = 0; // max per-channel distance from the chunk median for a pixel to count as solid
const FLAT_PIX_FRAC = 0.9; // min fraction of solid pixels for a chunk to count as flat
const FLAT_CHUNK = 4; // flatness is checked in chunks of FLAT_CHUNK * merge tolerance
const FLAT_MIN_FRAC = 0.5; // min fraction of chunks with a flat side to keep an edge

const round = (x) => Math.floor(x + 0.5);

// Detect UI borders and separators as horizontal/vertical line segments: long runs of
// colour change between adjacent pixel rows/columns, merged per edge, dropping edges
// with texture on both sides (photos).
const detectLines = async function(filePath) {
  const image = await Jimp.read(filePath);
  const { data, width: w, height: h } = image.bitmap;
  const px = (x, y, c) => data[(y * w + x) * 4 + c];
  const diff = (x1, y1, x2, y2) => Math.max(
    Math.abs(px(x1, y1, 0) - px(x2, y2, 0)),
    Math.abs(px(x1, y1, 1) - px(x2, y2, 1)),
    Math.abs(px(x1, y1, 2) - px(x2, y2, 2)),
  );
  const tol = Math.max(2, round(h * EDGE_TOL_FRAC));

  // Horizontal edges: row r sits between pixel rows r and r + 1.
  const horizontal = mergeRuns(
    runs(h - 1, w, (r, c) => diff(c, r + 1, c, r) >= EDGE_THRESHOLD, round(w * MIN_LINE_FRAC)),
    tol,
  ).filter(e => hasFlatSide(h, (r, i, c) => px(i, r, c), e, tol));

  // Vertical edges: row r sits between pixel columns r and r + 1.
  const vertical = mergeRuns(
    runs(w - 1, h, (r, c) => diff(r + 1, c, r, c) >= EDGE_THRESHOLD, round(h * MIN_LINE_FRAC)),
    tol,
  ).filter(e => hasFlatSide(w, (r, i, c) => px(r, i, c), e, tol));

  return [
    ...vertical.map(([p0, p1, a, b]) => ({
      text: "|",
      origin: { x: (p0 + p1) / 2 / w, y: a / h },
      size: { width: 0, height: (b - a) / h },
    })),
    ...horizontal.map(([p0, p1, a, b]) => ({
      text: "_",
      origin: { x: a / w, y: (p0 + p1) / 2 / h },
      size: { width: (b - a) / w, height: 0 },
    })),
    { text: "|", origin: { x: 0, y: 0 }, size: { width: 0, height: 1 } },
    { text: "|", origin: { x: 1, y: 0 }, size: { width: 0, height: 1 } },
    { text: "_", origin: { x: 0, y: 0 }, size: { width: 1, height: 0 } },
    { text: "_", origin: { x: 0, y: 1 }, size: { width: 1, height: 0 } },
  ];
}

// [row, start, end) for each run of isEdge(row, col) along each row with length >= minLen.
function runs(rows, cols, isEdge, minLen) {
  const out = [];
  for (let r = 0; r < rows; r++) {
    let start = -1;
    for (let c = 0; c <= cols; c++) {
      if (c < cols && isEdge(r, c)) {
        if (start < 0) start = c;
      } else if (start >= 0) {
        if (c - start >= minLen) out.push([r, start, c]);
        start = -1;
      }
    }
  }
  return out;
}

// Merge runs within tol rows of each other whose spans overlap or nearly touch.
// Returns [firstRow, lastRow, start, end] per merged edge.
function mergeRuns(runList, tol) {
  const sorted = [...runList].sort((x, y) => x[0] - y[0] || x[1] - y[1] || x[2] - y[2]);
  const edges = [];
  for (const [row, a, b] of sorted) {
    let target = null;
    for (let i = edges.length - 1; i >= 0; i--) {
      const e = edges[i];
      if (row - e[0] > tol) break;
      if (a <= e[3] + tol && b >= e[2] - tol) {
        target = e;
        break;
      }
    }
    if (target === null) {
      edges.push([row, row, a, b]);
    } else {
      target[1] = row;
      target[2] = Math.min(target[2], a);
      target[3] = Math.max(target[3], b);
    }
  }
  return edges;
}

// True if, along most of the edge, the strip just before or after it is a solid colour.
// UI fills repeat the exact same pixel value; smooth photo regions do not.
// Checked in chunks so a separator between differently coloured cells still counts.
// get(row, i, channel) reads pixel i along line `row`.
function hasFlatSide(rows, get, [p0, p1, a, b], offset) {
  const before = p0 - offset + 1, after = p1 + offset;
  if (before >= 0 && after < rows) {
    let contrast = 0;
    for (let i = a; i < b; i++) {
      let across = 0, strong = 0;
      for (let c = 0; c < 3; c++) {
        across = Math.max(across, Math.abs(get(before, i, c) - get(after, i, c)));
        for (let r = p0; r <= p1; r++) {
          strong = Math.max(strong, Math.abs(get(r + 1, i, c) - get(r, i, c)));
        }
      }
      if (across >= EDGE_THRESHOLD || strong >= STRONG_EDGE_THRESHOLD) contrast++;
    }
    // Reject faint narrow stripes whose two surrounding regions are the same.
    if (contrast / (b - a) < FLAT_MIN_FRAC) return false;
  }
  const n = b - a;
  const nChunks = Math.max(1, Math.floor(n / (offset * FLAT_CHUNK)));
  const flat = new Array(nChunks).fill(false);
  for (const r of [p0 - offset + 1, p1 + offset]) {
    if (r < 0 || r >= rows) continue;
    for (let k = 0; k < nChunks; k++) {
      const lo = a + Math.floor(k * n / nChunks), hi = a + Math.floor((k + 1) * n / nChunks);
      const near = new Array(hi - lo).fill(true);
      for (let c = 0; c < 3; c++) {
        const vals = [];
        for (let i = lo; i < hi; i++) vals.push(get(r, i, c));
        const sorted = [...vals].sort((x, y) => x - y);
        const m = sorted.length;
        const median = m % 2 ? sorted[(m - 1) / 2] : (sorted[m / 2 - 1] + sorted[m / 2]) / 2;
        vals.forEach((v, i) => { if (Math.abs(v - median) > FLAT_TOL) near[i] = false; });
      }
      if (near.filter(Boolean).length / (hi - lo) >= FLAT_PIX_FRAC) flat[k] = true;
    }
  }
  return flat.filter(Boolean).length / nChunks >= FLAT_MIN_FRAC;
}

module.exports = {
  detectLines,
}
