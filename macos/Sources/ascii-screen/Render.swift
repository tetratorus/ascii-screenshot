import Foundation

// Port of ascii.js. Keep in sync; tests/test_rendering.py checks parity.

struct Obs { var text: String; var x, y, w, h: Double } // Vision box: normalized, bottom-left origin
struct DLine { var vertical: Bool; var x, y, w, h: Double } // normalized, top-left origin
struct RenderResult { var originalText: String; var linesText: String; var finalText: String }

@inline(__always) func jsFloor(_ v: Double) -> Int { v.isFinite ? Int(v.rounded(.down)) : 0 }
@inline(__always) func jsRound(_ v: Double) -> Int { jsFloor(v + 0.5) }

private let separators: Set<String> = [".", ",", "\"", "'", ":", ";", "!", "?", "{", "}", "\u{2019}", "\u{201D}"]
private let pointer: Unicode.Scalar = "\u{1F446}"

func formatText(_ ocr: [Obs], _ W: Int, _ H: Int) -> [[UInt16]] {
  var clusters = [[(Int, Obs)]](repeating: [], count: H)
  for (n, a) in ocr.enumerated() {
    clusters[min(H - 1, max(0, jsFloor((1 - a.y) * Double(H))))].append((n, a))
  }
  var canvas = [[UInt16]](repeating: [UInt16](repeating: 32, count: W), count: H)
  for i in 0..<H {
    let line = clusters[i].sorted { $0.1.x != $1.1.x ? $0.1.x < $1.1.x : $0.0 < $1.0 }.map { $0.1 }
    var lastX = 0
    for g in groupWords(line) {
      let t = Array(g.text.utf16)
      let startX = max(jsFloor(g.x * Double(W)), lastX)
      for (j, u) in t.enumerated() where startX + j >= 0 && startX + j < W { canvas[i][startX + j] = u }
      lastX = startX + t.count + 1
    }
  }
  return canvas
}

func groupWords(_ anns: [Obs]) -> [Obs] {
  var out: [Obs] = [], cur: [Obs] = []
  for a in anns {
    guard let prev = cur.last else { cur.append(a); continue }
    let charWidth = prev.w / Double(prev.text.utf16.count) * 2
    if a.x <= prev.x + prev.w + charWidth { cur.append(a) } else { out.append(grouped(cur)); cur = [a] }
  }
  if !cur.isEmpty { out.append(grouped(cur)) }
  return out
}

private func grouped(_ g: [Obs]) -> Obs {
  var text = ""
  for (i, w) in g.enumerated() {
    text += separators.contains(w.text) ? w.text : (i > 0 ? " " : "") + w.text
  }
  return Obs(text: text, x: g[0].x, y: g[0].y, w: g.reduce(0) { $0 + $1.w }, h: g[0].h)
}

func renderAscii(_ ocr: [Obs], _ lines: [DLine], _ nx: Double?, _ ny: Double?, _ W: Int, _ H: Int) -> RenderResult {
  var canvas = formatText(ocr, W, H).map { Array(String(decoding: $0, as: UTF16.self).unicodeScalars) }
  if let nx, let ny, !canvas.isEmpty {
    let len = canvas[0].count
    let cx = min(len - 1, jsRound(nx * Double(len))), cy = min(canvas.count - 1, jsRound(ny * Double(canvas.count)))
    if cy >= 0 && cx >= 0 && cx < canvas[cy].count { canvas[cy][cx] = pointer }
  }
  let border = String(repeating: "_", count: W)
  let bordered = ([border] + canvas.map { String(String.UnicodeScalarView($0)) } + [border]).joined(separator: "\n")
  return addLines(bordered, lines.filter { !isTextEdge($0, ocr) }, W, H)
}

private struct HLine { var y, x0, x1: Int }
private struct VLine { var x, y0, y1: Int }

func addLines(_ asciiLines: String, _ lineData: [DLine], _ W: Int, _ H: Int) -> RenderResult {
  let Wd = Double(W), Hd = Double(H)
  func cx(_ v: Int) -> Int { max(0, min(v, W - 1)) }
  func cy(_ v: Int) -> Int { max(0, min(v, H - 1)) }
  var hs: [HLine] = [], vs: [VLine] = []
  for l in lineData {
    if l.vertical {
      vs.append(VLine(x: cx(jsFloor(l.x * Wd)), y0: cy(jsFloor(l.y * Hd)), y1: cy(jsFloor((l.y + l.h) * Hd))))
    } else {
      let x0 = cx(jsFloor(l.x * Wd))
      hs.append(HLine(y: cy(jsFloor(l.y * Hd)), x0: x0, x1: cx(x0 + jsFloor(l.w * Wd))))
    }
  }
  snapCorners(&hs, &vs)

  var lc = [[UInt8]](repeating: [UInt8](repeating: 32, count: W), count: H)
  for h in hs where h.x0 <= h.x1 { for x in h.x0...h.x1 { lc[h.y][x] = 95 } }
  for v in vs { for y in v.y0...v.y1 { lc[y][v.x] = 124 } }
  let blanks = vs.filter { v in
    v.y0 > 0 && lc[v.y0 - 1][v.x] == 95 &&
      ((v.x > 0 && lc[v.y0 - 1][v.x - 1] == 95) != (v.x + 1 < W && lc[v.y0 - 1][v.x + 1] == 95))
  }
  for v in blanks { lc[v.y0 - 1][v.x] = 32 }
  let linesText = lc.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")

  let rows = asciiLines.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
  var out: [String] = []
  if rows.count > 2 {
    for (ri, row) in rows[1..<(rows.count - 1)].enumerated() {
      var s = String.UnicodeScalarView()
      for (ci, ch) in row.enumerated() {
        let l: UInt8 = ri < H && ci < W ? lc[ri][ci] : 32
        if ch == pointer { s.append(ch) }
        else if ch == " " || l == 124 { s.append(Unicode.Scalar(l)) }
        else if l == 95 { s.append(ch); s.append("\u{0332}") }
        else { s.append(ch) }
      }
      out.append(String(s))
    }
  }
  return RenderResult(originalText: asciiLines, linesText: linesText, finalText: out.joined(separator: "\n"))
}

private func nearest(_ cands: [Int], _ t: Int) -> Int? {
  var best: Int?
  for c in cands where best == nil || abs(c - t) < abs(best! - t) { best = c }
  return best
}

private func snapCorners(_ hs: inout [HLine], _ vs: inout [VLine]) {
  for i in hs.indices {
    let h = hs[i]
    let cols = vs.filter { h.y >= $0.y0 - 1 && h.y <= $0.y1 + 1 }.map { $0.x }
    let x0 = nearest(cols.filter { abs($0 - h.x0) <= 1 }, h.x0)
    let x1 = nearest(cols.filter { abs($0 - h.x1) <= 1 }, h.x1)
    if let x0 { hs[i].x0 = x0 }
    if let x1 { hs[i].x1 = x1 }
  }
  for i in vs.indices {
    let v = vs[i]
    let rows = hs.filter { v.x >= $0.x0 && v.x <= $0.x1 }.map { $0.y }
    let top = nearest(rows.filter { abs($0 - v.y0) <= 1 }, v.y0)
    let bottom = nearest(rows.filter { abs($0 - v.y1) <= 1 }, v.y1)
    if top != nil && top == bottom { continue }
    if let top { vs[i].y0 = top + 1 }
    if let bottom { vs[i].y1 = bottom }
  }
  vs.removeAll { $0.y0 > $0.y1 }
}

func isTextEdge(_ l: DLine, _ ocr: [Obs]) -> Bool {
  let v = l.vertical
  let pos = v ? l.x : l.y, start = v ? l.y : l.x, length = v ? l.h : l.w
  if length == 1 && (pos == 0 || pos == 1) { return false }
  for b in ocr {
    let top = 1 - b.y - b.h
    let lo = v ? top : b.x, hi = lo + (v ? b.h : b.w)
    let side = v ? b.x : top, sideEnd = side + (v ? b.w : b.h)
    let overlap = max(0, min(start + length, hi) - max(start, lo))
    if pos >= side && pos <= sideEnd && length > 0 && overlap >= 0.8 * length { return true }
  }
  return false
}
