import Foundation

struct Obs { var text: String; var x, y, w, h: Double } // Vision box: normalized, bottom-left origin
struct DLine { var vertical: Bool; var x, y, w, h: Double } // normalized, top-left origin
struct RenderResult { var originalText: String; var linesText: String; var finalText: String }

@inline(__always) func jsFloor(_ v: Double) -> Int { v.isFinite ? Int(v.rounded(.down)) : 0 }
@inline(__always) func jsRound(_ v: Double) -> Int { jsFloor(v + 0.5) }

private let separators: Set<String> = [".", ",", "\"", "'", ":", ";", "!", "?", "{", "}", "\u{2019}", "\u{201D}"]
private let pointer: Character = "\u{1F446}"

/// Terminal columns a character takes: emoji and East Asian wide characters take two.
func columns(_ c: Character) -> Int {
  guard let s = c.unicodeScalars.first else { return 0 }
  if s.properties.isEmojiPresentation { return 2 }
  switch s.value {
  case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
       0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
    return 2
  default: return 1
  }
}

/// Shortens text to `room` columns by keeping its start and its last few characters around a "…".
func fit(_ t: [Character], _ room: Int) -> [Character] {
  func take(_ cs: some Sequence<Character>, _ n: Int) -> [Character] {
    var out: [Character] = [], w = 0
    for c in cs { w += columns(c); if w > n { break }; out.append(c) }
    return out
  }
  guard t.reduce(0, { $0 + columns($1) }) > room else { return t }
  guard room > 2 else { return take(t, room) }
  let tail = Array(take(t.reversed(), min(5, (room - 1) / 2)).reversed())
  return take(t, room - 1 - tail.reduce(0) { $0 + columns($1) }) + ["…"] + tail
}

/// Text laid out on a W x H grid of terminal cells; "" marks the second cell of a wide character.
/// `walls[row]` holds the columns of vertical lines on that row: text that would run into one is shortened.
func formatText(_ ocr: [Obs], _ W: Int, _ H: Int, walls: [[Int]] = []) -> [[String]] {
  var clusters = [[(Int, Obs)]](repeating: [], count: H)
  for (n, a) in ocr.enumerated() {
    clusters[min(H - 1, max(0, jsFloor((1 - a.y) * Double(H))))].append((n, a))
  }
  var canvas = [[String]](repeating: [String](repeating: " ", count: W), count: H)
  for i in 0..<H {
    let line = clusters[i].sorted { $0.1.x != $1.1.x ? $0.1.x < $1.1.x : $0.0 < $1.0 }.map { $0.1 }
    var lastX = 0
    for g in groupWords(line) {
      let startX = max(jsFloor(g.x * Double(W)), lastX)
      let end = (i < walls.count ? walls[i] : []).first { $0 > startX } ?? W
      var x = startX
      for c in fit(Array(g.text), end - startX) {
        let w = columns(c)
        if x >= 0 && x + w <= W {
          canvas[i][x] = String(c)
          if w == 2 { canvas[i][x + 1] = "" }
        }
        x += w
      }
      lastX = x + 1
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
  let grid = gridLines(lines.filter { !isTextEdge($0, ocr) }, W, H)
  var walls = [[Int]](repeating: [], count: H)
  for v in grid.vs { for y in v.y0...v.y1 { walls[y].append(v.x) } }
  var canvas = formatText(ocr, W, H, walls: walls.map { $0.sorted() })
  if let nx, let ny, !canvas.isEmpty, W >= 2 {
    let cx = min(W - 1, jsRound(nx * Double(W))), cy = min(H - 1, jsRound(ny * Double(H)))
    if cy >= 0 && cx >= 0 { // the emoji is two columns wide
      let x = min(cx, W - 2)
      if canvas[cy][x] == "" { canvas[cy][x - 1] = " " }
      if x + 2 < W && canvas[cy][x + 2] == "" { canvas[cy][x + 2] = " " }
      canvas[cy][x] = String(pointer); canvas[cy][x + 1] = ""
    }
  }
  let border = String(repeating: "_", count: W)
  let bordered = ([border] + canvas.map { $0.joined() } + [border]).joined(separator: "\n")
  return addLines(bordered, grid, W, H)
}

private struct HLine { var y, x0, x1: Int }
private struct VLine { var x, y0, y1: Int }

func addLines(_ asciiLines: String, _ lineData: [DLine], _ W: Int, _ H: Int) -> RenderResult {
  addLines(asciiLines, gridLines(lineData, W, H), W, H)
}

private func gridLines(_ lineData: [DLine], _ W: Int, _ H: Int) -> (hs: [HLine], vs: [VLine]) {
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
  return (hs, vs)
}

private func addLines(_ asciiLines: String, _ grid: (hs: [HLine], vs: [VLine]), _ W: Int, _ H: Int) -> RenderResult {
  let (hs, vs) = grid
  var lc = [[UInt8]](repeating: [UInt8](repeating: 32, count: W), count: H)
  for h in hs where h.x0 <= h.x1 { for x in h.x0...h.x1 { lc[h.y][x] = 95 } }
  for v in vs { for y in v.y0...v.y1 { lc[y][v.x] = 124 } }
  let blanks = vs.filter { v in
    v.y0 > 0 && lc[v.y0 - 1][v.x] == 95 &&
      ((v.x > 0 && lc[v.y0 - 1][v.x - 1] == 95) != (v.x + 1 < W && lc[v.y0 - 1][v.x + 1] == 95))
  }
  for v in blanks { lc[v.y0 - 1][v.x] = 32 }
  let linesText = lc.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")

  let rows = asciiLines.split(separator: "\n", omittingEmptySubsequences: false)
  var out: [String] = []
  if rows.count > 2 {
    for (ri, row) in rows[1..<(rows.count - 1)].enumerated() {
      func l(_ c: Int) -> UInt8 { ri < H && c < W ? lc[ri][c] : 32 }
      var s = ""
      var ci = 0
      for ch in row {
        let w = columns(ch), c = ci
        ci += w
        if ch == pointer { s.append(ch) }
        else if w == 2 && (l(c) == 124 || l(c + 1) == 124) { // a wide character under a vertical line gives way to it
          s.append(Character(Unicode.Scalar(l(c) == 95 ? 32 : l(c))))
          s.append(Character(Unicode.Scalar(l(c + 1) == 95 ? 32 : l(c + 1))))
        }
        else if ch == " " || l(c) == 124 { s.append(Character(Unicode.Scalar(l(c)))) }
        else if l(c) == 95 { s.append(ch); s.append("\u{0332}") }
        else { s.append(ch) }
      }
      out.append(s)
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
