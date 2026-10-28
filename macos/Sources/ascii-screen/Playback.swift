import Foundation

/// Plays saved history in the terminal like a screen recording: frames are shown at their recorded
/// spacing divided by `speed`, with long idle gaps capped at `maxGap` real seconds.
/// Frames are pulled from `source` as playback reaches them; only the last `keepBack` are kept for stepping
/// back, so memory stays flat however long the range is.
struct Playback {
  private var source: AnyIterator<(Date, String)>
  private var window: [(Date, String)] = []
  private(set) var first = 0
  private var ended = false
  static let keepBack = 1000
  var speed: Double
  let maxGap: Double

  init<S: Sequence>(frames: S, speed: Double, maxGap: Double) where S.Element == (Date, String) {
    var it = frames.makeIterator()
    source = AnyIterator { it.next() }
    self.speed = speed
    self.maxGap = maxGap
  }

  /// Frame `i`, reading ahead as needed; nil past the end or before the kept window.
  mutating func frame(_ i: Int) -> (Date, String)? {
    while i >= first + window.count && !ended {
      guard let f = source.next() else { ended = true; break }
      window.append(f)
      if window.count > Playback.keepBack { window.removeFirst(); first += 1 }
    }
    return i >= first && i < first + window.count ? window[i - first] : nil
  }

  mutating func isLast(_ i: Int) -> Bool { frame(i + 1) == nil }

  /// Real seconds to keep frame `i` on screen before showing frame `i + 1`.
  mutating func delay(after i: Int) -> Double {
    guard let a = frame(i), let b = frame(i + 1) else { return 0 }
    return max(0, min(b.0.timeIntervalSince(a.0) / speed, maxGap))
  }

  enum Key: Equatable { case quit, pause, faster, slower, next, previous, other }

  /// Split one read() into key presses (arrow keys arrive as 3-byte escape sequences).
  static func keys(_ bytes: [UInt8]) -> [Key] {
    var out: [Key] = [], i = 0
    while i < bytes.count {
      let n = bytes[i] == 0x1b && i + 2 < bytes.count && bytes[i + 1] == 0x5b ? 3 : 1
      out.append(key(Array(bytes[i..<i + n])))
      i += n
    }
    return out
  }

  static func key(_ bytes: [UInt8]) -> Key {
    switch bytes {
    case [0x71], [0x51], [0x03]: return .quit                                  // q Q ctrl-c
    case [0x20], [0x70]: return .pause                                         // space p
    case [0x2b], [0x3d], [0x1b, 0x5b, 0x41]: return .faster                    // + = up
    case [0x2d], [0x5f], [0x1b, 0x5b, 0x42]: return .slower                    // - _ down
    case [0x6c], [0x2e], [0x1b, 0x5b, 0x43]: return .next                      // l . right
    case [0x68], [0x2c], [0x1b, 0x5b, 0x44]: return .previous                  // h , left
    default: return .other
    }
  }

  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  mutating func status(_ i: Int, paused: Bool) -> String {
    let state = paused ? (isLast(i) ? "end" : "paused") : "playing"
    let total = ended ? "/\(first + window.count)" : ""
    let x = speed >= 1 ? String(format: "%gx", speed) : String(format: "%.3gx", speed)
    return "\(Playback.clock.string(from: frame(i)!.0))  frame \(i + 1)\(total)  \(x)  \(state)"
      + "   space pause  left/right step  up/down speed  q quit"
  }

  mutating func run() {
    let interactive = isatty(0) != 0 && isatty(1) != 0
    var saved = termios()
    if interactive {
      tcgetattr(0, &saved)
      var raw = saved
      raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
      tcsetattr(0, TCSANOW, &raw)
      write("\u{1b}[?1049h\u{1b}[?25l")
    }
    defer {
      if interactive {
        write("\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(0, TCSANOW, &saved)
      }
    }

    var i = 0, paused = false
    var deadline = Date().addingTimeInterval(delay(after: i))
    while true {
      if isLast(i) { paused = true }
      draw(i, paused: paused, interactive: interactive)
      if !interactive {
        if isLast(i) { return }
        Thread.sleep(forTimeInterval: delay(after: i))
        i += 1
        continue
      }
      let wait = paused ? -1 : Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
      if let keys = readKeys(timeoutMs: wait) {
        for k in keys {
          switch k {
          case .quit: return
          case .pause: paused.toggle()
          case .faster: speed = min(speed * 2, 4096)
          case .slower: speed = max(speed / 2, 1.0 / 64)
          case .next: if !isLast(i) { i += 1 }
          case .previous: i = max(i - 1, first); paused = true
          case .other: break
          }
        }
        if keys.contains(where: { $0 != .other }) { deadline = Date().addingTimeInterval(delay(after: i)) }
        continue
      }
      if !paused {
        i += 1
        deadline = Date().addingTimeInterval(delay(after: i))
      }
    }
  }

  private mutating func draw(_ i: Int, paused: Bool, interactive: Bool) {
    let f = frame(i)!
    if interactive {
      var ws = winsize()
      let size = ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 ? (Int(ws.ws_col), Int(ws.ws_row)) : (Int.max, Int.max)
      let body = f.1.split(separator: "\n", omittingEmptySubsequences: false)
        .prefix(max(size.1 - 1, 1)).map { $0.prefix(size.0) }.joined(separator: "\u{1b}[K\n")
      write("\u{1b}[H" + body + "\u{1b}[K\n\u{1b}[7m" + String(status(i, paused: paused).prefix(size.0))
            + "\u{1b}[0m\u{1b}[K\u{1b}[J")
    } else {
      write("@@ " + History.stamp(f.0) + "\n" + f.1 + "\n")
    }
  }

  /// Key presses, or nil when `timeoutMs` passes first (-1 waits forever).
  private func readKeys(timeoutMs: Int32) -> [Key]? {
    var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    guard poll(&fds, 1, timeoutMs) > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 8)
    let n = read(0, &buf, buf.count)
    guard n > 0 else { return [.quit] }
    return Playback.keys(Array(buf[..<n]))
  }

  private func write(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
  }
}
