import CoreGraphics
import Foundation

/// Everything read from one screen frame, before it is squeezed onto a grid: every text box and line at its
/// position, so history can be drawn again at any grid size. Saved as a history record body:
///
///     #frame 1600 1200          capture size in pixels
///     c 5000 2500               pointer, if on screen
///     t 120 9520 2400 180 Inbox text box: x y w h (bottom-left origin, as Vision gives it), then the text
///     l h 0 900 10000 0         line: h or v, x y w h (top-left origin)
///
/// Positions are in 1/10000 of the screen width/height. `quantized()` rounds to that step, so a frame drawn
/// live and the same frame drawn from history come out identical.
struct Frame {
  static let header = "#frame "
  var width: Int, height: Int
  var obs: [Obs]
  var lines: [DLine]
  var cursor: CGPoint?

  /// Rows that keep the screen's shape at `columns` (terminal cells are about twice as tall as wide).
  static func rows(columns: Int, width: Int, height: Int) -> Int {
    width > 0 ? min(100, max(1, jsFloor(Double(columns) * Double(height) / Double(width) * 0.5))) : 1
  }

  func quantized() -> Frame {
    func q(_ v: Double) -> Double { Double(Int((v * 10000).rounded())) / 10000 }
    return Frame(width: width, height: height,
                 obs: obs.map { Obs(text: $0.text.replacingOccurrences(of: "\n", with: " "), x: q($0.x), y: q($0.y), w: q($0.w), h: q($0.h)) },
                 lines: lines.map { DLine(vertical: $0.vertical, x: q($0.x), y: q($0.y), w: q($0.w), h: q($0.h)) },
                 cursor: cursor.map { CGPoint(x: q(Double($0.x)), y: q(Double($0.y))) })
  }

  func render(columns: Int, rows: Int? = nil) -> String {
    renderAscii(obs, lines, cursor.map { Double($0.x) }, cursor.map { Double($0.y) }, columns,
                rows ?? Frame.rows(columns: columns, width: width, height: height)).finalText
  }

  /// The text that was read, one box per line, top to bottom.
  var text: String {
    obs.sorted { ($0.y + $0.h, -$0.x) > ($1.y + $1.h, -$1.x) }.map(\.text).joined(separator: "\n")
  }

  func encode() -> String {
    func n(_ v: Double) -> String { String(Int((v * 10000).rounded())) }
    var out = Frame.header + "\(width) \(height)\n"
    if let c = cursor { out += "c \(n(c.x)) \(n(c.y))\n" }
    for o in obs {
      let t = o.text.replacingOccurrences(of: "\n", with: " ")
      out += "t \(n(o.x)) \(n(o.y)) \(n(o.w)) \(n(o.h)) \(t)\n"
    }
    for l in lines { out += "l \(l.vertical ? "v" : "h") \(n(l.x)) \(n(l.y)) \(n(l.w)) \(n(l.h))\n" }
    return String(out.dropLast())
  }

  /// nil for anything that isn't a saved frame, e.g. a record from before frames were saved this way.
  static func decode(_ s: String) -> Frame? {
    guard s.hasPrefix(header) else { return nil }
    var f = Frame(width: 0, height: 0, obs: [], lines: [], cursor: nil)
    for (i, line) in s.split(separator: "\n").enumerated() {
      if i == 0 {
        let p = line.dropFirst(header.count).split(separator: " ").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        (f.width, f.height) = (p[0], p[1])
        continue
      }
      let p = line.split(separator: " ", maxSplits: line.hasPrefix("t ") ? 5 : 6, omittingEmptySubsequences: false)
      func v(_ i: Int) -> Double { i < p.count ? (Double(p[i]) ?? 0) / 10000 : 0 }
      switch p.first {
      case "c": f.cursor = CGPoint(x: v(1), y: v(2))
      case "t" where p.count == 6: f.obs.append(Obs(text: String(p[5]), x: v(1), y: v(2), w: v(3), h: v(4)))
      case "l" where p.count == 6: f.lines.append(DLine(vertical: p[1] == "v", x: v(2), y: v(3), w: v(4), h: v(5)))
      default: break
      }
    }
    return f
  }
}

extension History {
  /// A record as it is shown: saved frames drawn at the given grid, older (pre-drawn) records unchanged.
  static func display(_ body: String, columns: Int, rows: Int?) -> String {
    Frame.decode(body)?.render(columns: columns, rows: rows) ?? body
  }

  /// A record's text for searching.
  static func text(_ body: String) -> String {
    Frame.decode(body)?.text ?? body.replacingOccurrences(of: "\u{0332}", with: "")
  }
}
