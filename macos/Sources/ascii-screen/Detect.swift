import Foundation

// Port of detect_lines.js over a BGRA buffer. Keep constants and logic in sync;
// tests/test_boundaries.py checks parity.
private let edgeThreshold: Int32 = 4
private let strongEdgeThreshold: Int32 = 10
private let minLineFrac = 0.025
private let edgeTolFrac = 0.004
private let flatPixFrac = 0.9
private let flatChunk = 4
private let flatMinFrac = 0.5

struct Bitmap {
  let base: UnsafePointer<UInt8>
  let width: Int, height: Int, rowBytes: Int
  @inline(__always) func px(_ x: Int, _ y: Int, _ c: Int) -> Int32 { Int32(base[y &* rowBytes &+ x &* 4 &+ c]) }
}

@inline(__always) private func diff3(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>) -> Int32 {
  max(abs(Int32(a[0]) - Int32(b[0])), abs(Int32(a[1]) - Int32(b[1])), abs(Int32(a[2]) - Int32(b[2])))
}

func detectLines(_ bm: Bitmap) -> [DLine] {
  let w = bm.width, h = bm.height, rb = bm.rowBytes, base = bm.base
  let tol = max(2, jsRound(Double(h) * edgeTolFrac))

  // Horizontal edge runs: row r sits between pixel rows r and r + 1.
  let minH = jsRound(Double(w) * minLineFrac)
  var hRuns: [(Int, Int, Int)] = []
  for r in 0..<max(0, h - 1) {
    let a = base + r * rb, b = a + rb
    var start = -1
    for c in 0...w {
      if c < w && diff3(a + c * 4, b + c * 4) >= edgeThreshold {
        if start < 0 { start = c }
      } else if start >= 0 {
        if c - start >= minH { hRuns.append((r, start, c)) }
        start = -1
      }
    }
  }

  // Vertical edge runs: row r sits between pixel columns r and r + 1. Scanned row-major.
  let minV = jsRound(Double(h) * minLineFrac)
  var vRuns: [(Int, Int, Int)] = []
  var starts = [Int](repeating: -1, count: max(0, w - 1))
  for y in 0...h {
    let row = base + min(y, h - 1) * rb
    for x in 0..<max(0, w - 1) {
      if y < h && diff3(row + x * 4 + 4, row + x * 4) >= edgeThreshold {
        if starts[x] < 0 { starts[x] = y }
      } else if starts[x] >= 0 {
        if y - starts[x] >= minV { vRuns.append((x, starts[x], y)) }
        starts[x] = -1
      }
    }
  }

  let horizontal = mergeRuns(hRuns, tol).filter { hasFlatSide(h, { r, i, c in bm.px(i, r, c) }, $0, tol) }
  let vertical = mergeRuns(vRuns, tol).filter { hasFlatSide(w, { r, i, c in bm.px(r, i, c) }, $0, tol) }
  let W = Double(w), H = Double(h)
  return vertical.map { DLine(vertical: true, x: Double($0[0] + $0[1]) / 2 / W, y: Double($0[2]) / H, w: 0, h: Double($0[3] - $0[2]) / H) }
    + horizontal.map { DLine(vertical: false, x: Double($0[2]) / W, y: Double($0[0] + $0[1]) / 2 / H, w: Double($0[3] - $0[2]) / W, h: 0) }
    + [DLine(vertical: true, x: 0, y: 0, w: 0, h: 1), DLine(vertical: true, x: 1, y: 0, w: 0, h: 1),
       DLine(vertical: false, x: 0, y: 0, w: 1, h: 0), DLine(vertical: false, x: 0, y: 1, w: 1, h: 0)]
}

private func mergeRuns(_ runs: [(Int, Int, Int)], _ tol: Int) -> [[Int]] {
  let sorted = runs.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
  var edges: [[Int]] = []
  for (row, a, b) in sorted {
    var target = -1
    var i = edges.count - 1
    while i >= 0 {
      let e = edges[i]
      if row - e[0] > tol { break }
      if a <= e[3] + tol && b >= e[2] - tol { target = i; break }
      i -= 1
    }
    if target < 0 {
      edges.append([row, row, a, b])
    } else {
      edges[target][1] = row
      edges[target][2] = min(edges[target][2], a)
      edges[target][3] = max(edges[target][3], b)
    }
  }
  return edges
}

private func hasFlatSide(_ rows: Int, _ get: (Int, Int, Int) -> Int32, _ e: [Int], _ offset: Int) -> Bool {
  let p0 = e[0], p1 = e[1], a = e[2], b = e[3]
  let before = p0 - offset + 1, after = p1 + offset
  if before >= 0 && after < rows {
    var contrast = 0
    for i in a..<b {
      var across: Int32 = 0, strong: Int32 = 0
      for c in 0..<3 {
        across = max(across, abs(get(before, i, c) - get(after, i, c)))
        for r in p0...p1 { strong = max(strong, abs(get(r + 1, i, c) - get(r, i, c))) }
      }
      if across >= edgeThreshold || strong >= strongEdgeThreshold { contrast += 1 }
    }
    if Double(contrast) / Double(b - a) < flatMinFrac { return false }
  }
  let n = b - a
  let nChunks = max(1, n / (offset * flatChunk))
  var flat = [Bool](repeating: false, count: nChunks)
  var vals = [Int32](), sorted = [Int32](), near = [Bool]()
  for r in [p0 - offset + 1, p1 + offset] where r >= 0 && r < rows {
    for k in 0..<nChunks {
      let lo = a + k * n / nChunks, hi = a + (k + 1) * n / nChunks
      near = [Bool](repeating: true, count: hi - lo)
      for c in 0..<3 {
        vals.removeAll(keepingCapacity: true)
        for i in lo..<hi { vals.append(get(r, i, c)) }
        sorted = vals.sorted()
        let m = sorted.count
        let median2 = m % 2 == 1 ? 2 * sorted[(m - 1) / 2] : sorted[m / 2 - 1] + sorted[m / 2]
        for (j, v) in vals.enumerated() where 2 * v != median2 { near[j] = false }
      }
      if Double(near.lazy.filter { $0 }.count) / Double(hi - lo) >= flatPixFrac { flat[k] = true }
    }
  }
  return Double(flat.lazy.filter { $0 }.count) / Double(nChunks) >= flatMinFrac
}
