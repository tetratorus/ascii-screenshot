import Foundation
import zlib

/// Keeps every distinct frame, compressed, in one gzip file per day (`YYYY-MM-DD.txt.gz`).
/// Frames are buffered in memory and appended as one gzip member per flush: at most `flushEvery`
/// seconds after the first buffered frame (one timer per batch, none while the screen is static). Each record is a `@@ <ISO-8601 time>` line
/// followed by the frame; consecutive frames are nearly identical, so deflate stores mostly back-references.
/// Read with `gzcat <file>` or `ascii-screen --at <time>`.
final class History {
  static let marker = "@@ "
  let dir: URL
  private let flushEvery: TimeInterval
  private let keepDays: Int
  private let now: () -> Date
  private var buffer = ""
  private var bufferDay = ""
  private var firstBuffered: Date?
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private lazy var index: HistoryIndex? = {
    do { return try HistoryIndex(dir: dir) } catch { log("history search index unavailable: \(error.localizedDescription)"); return nil }
  }()

  init(dir: URL, flushEvery: TimeInterval = 10, keepDays: Int = 365, now: @escaping () -> Date = Date.init) {
    self.dir = dir
    self.flushEvery = flushEvery
    self.keepDays = keepDays
    self.now = now
  }

  func record(_ text: String) throws {
    let t = now()
    lock.lock()
    let day = History.day(t)
    var due = false
    if !buffer.isEmpty && day != bufferDay { lock.unlock(); try flush(); lock.lock() }
    if buffer.isEmpty { bufferDay = day; firstBuffered = t; scheduleFlush() }
    buffer += History.marker + History.stamp(t) + "\n" + text + "\n"
    due = t.timeIntervalSince(firstBuffered ?? t) >= flushEvery || buffer.utf8.count >= 4 << 20
    lock.unlock()
    if due { try flush() }
  }

  private func scheduleFlush() {
    timer?.cancel()
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    t.schedule(deadline: .now() + flushEvery, leeway: .milliseconds(Int(flushEvery * 200)))
    t.setEventHandler { [weak self] in
      do { try self?.flush() } catch { log("cannot write history: \(error.localizedDescription)") }
    }
    t.resume()
    timer = t
  }

  func flush() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !buffer.isEmpty else { return }
    timer?.cancel()
    timer = nil
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
      let url = dir.appendingPathComponent("\(bufferDay).txt.gz")
      let member = try gzip(Data(buffer.utf8))
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        prune()
      }
      let fh = try FileHandle(forWritingTo: url)
      defer { try? fh.close() }
      try fh.seekToEnd()
      try fh.write(contentsOf: member)
      try? fh.close()
      do { try index?.catchUp(day: bufferDay) } catch { log("cannot index history: \(error.localizedDescription)") }
    } catch {
      // Disk full or unwritable: retry with later frames, but don't let memory grow without bound.
      if buffer.utf8.count > 16 << 20 {
        buffer = ""
        firstBuffered = nil
        log("history: dropped unsaved frames after repeated write failures")
      }
      throw error
    }
    buffer = ""
    firstBuffered = nil
  }

  /// Delete day files older than `keepDays` (0 keeps everything).
  private func prune() {
    guard keepDays > 0,
          let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    let cutoff = History.day(now().addingTimeInterval(-Double(keepDays) * 86400))
    for f in files where f.hasSuffix(".txt.gz") && String(f.prefix(10)) < cutoff {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
      try? index?.drop(String(f.prefix(10)))
    }
  }

  /// The frame that was on screen at `time`: the last record at or before it.
  func frame(at time: Date) -> (Date, String)? { frames(from: time, to: time).next() }

  /// Every frame recorded between `from` and `to`, starting with the one already on screen at `from`.
  /// Read lazily, one gzip member at a time, so memory stays flat however long the range is. The index
  /// says which member to start from; without it, reading starts at the beginning of the day before.
  func frames(from: Date, to: Date) -> AnyIterator<(Date, String)> {
    let cal = Calendar.current
    try? index?.catchUp()
    let start = (try? index?.locate(atOrBefore: from)) ?? nil
    var day = start.flatMap { History.date(day: $0.day) } ?? cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: from))!
    var offset = start?.offset ?? 0
    var records: GzipRecords?
    var before: (Date, String)?, pending: (Date, String)?
    var started = false, done = false
    let last = max(from, to)
    return AnyIterator {
      if let p = pending { pending = nil; return p }
      while !done {
        if records == nil {
          if day > last { done = true; break }
          records = GzipRecords(url: self.dir.appendingPathComponent("\(History.day(day)).txt.gz"), from: offset)
          day = cal.date(byAdding: .day, value: 1, to: day)!
          offset = 0
          continue
        }
        guard let r = records!.next() else { records = nil; if day > last { done = true }; continue }
        if r.0 < from { before = r; continue }
        if r.0 > to { done = true; break }
        if !started {
          started = true
          if r.0 > from, let b = before { pending = r; return b }
        }
        return r
      }
      if !started { started = true; return before }
      return nil
    }
  }

  struct Match { var start: Date; var end: Date; var frames: Int; var line: String }

  /// Times matching frames were on screen between `from` and `to`, newest first; runs of consecutive matching
  /// frames are merged. `query` is FTS5 syntax (`invo*`, `a OR b`, `NOT`, `"exact phrase"`); plain words match
  /// in any order, each also matching longer words it starts. The index has no word positions, so a quoted
  /// phrase is looked up as its words and then checked against the frame text (unless the query uses OR).
  func search(_ query: String, from: Date, to: Date, limit: Int) throws -> [Match] {
    guard let index else { throw NSError(domain: "ascii-screen", code: 5, userInfo: [NSLocalizedDescriptionKey: "no search index"]) }
    try index.catchUp()
    let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
      .filter { !["and", "or", "not", "near"].contains($0) }
    let raw = query.contains { "\"*():^+".contains($0) } || query.split(separator: " ").contains { ["AND", "OR", "NOT"].contains($0) }
    let parts = query.split(separator: "\"", omittingEmptySubsequences: false).map(String.init)
    let quoted = parts.count > 1 && parts.count % 2 == 1
    let phrases = !quoted ? [] : stride(from: 1, to: parts.count, by: 2)
      .filter { parts[$0 - 1].split(separator: " ").last != "NOT" }.map { History.words(parts[$0]) }.filter { $0 != "  " }
    let match = !raw ? words.map { "\"\($0)\"*" }.joined(separator: " ")
      : !quoted && parts.count > 1 ? query
      : parts.indices.map { i in
        guard i % 2 == 1 else { return History.prefixWords(parts[i]) }
        let group = "(" + History.words(parts[i]).split(separator: " ").map { "\"\($0)\"" }.joined(separator: " AND ") + ")"
        let ops = ["AND", "OR", "NOT"], before = parts[i - 1].split(separator: " ").last, after = parts[i + 1].split(separator: " ").first
        return (before.map { !ops.contains(String($0)) && !$0.hasSuffix("(") } == true ? " AND " : "") + group
          + (after.map { !ops.contains(String($0)) && !$0.hasPrefix(")") && $0 != "*" } == true ? " AND " : "")
      }.joined()
    guard !match.isEmpty else { return [] }
    let verify = !phrases.isEmpty && !query.split(separator: " ").contains("OR")
    var out: [Match] = [], skip = 0, next = -1, cached: (day: String, offset: Int, records: [(Date, String)])?
    var runs: [HistoryIndex.Location] = []
    while out.count <= limit {
      let page = try index.candidates(match, from: from, to: to, limit: 1000, skip: skip)
      if page.isEmpty { break }
      skip += page.count
      for c in page {
        if verify {
          if cached?.day != c.day || cached?.offset != c.offset { cached = (c.day, c.offset, member(c)) }
          guard let recs = cached?.records, c.seq < recs.count,
                case let lines = recs[c.seq].1.split(separator: "\n").map({ History.words(String($0)) }),
                phrases.allSatisfy({ p in lines.contains { $0.contains(p) } }) else { next = -1; continue }
        }
        if !out.isEmpty, next == c.id {
          out[out.count - 1].start = c.time
          out[out.count - 1].frames += 1
        } else {
          out.append(Match(start: c.time, end: c.time, frames: 1, line: ""))
          runs.append(c)
        }
        next = c.older
      }
    }
    out = Array(out.prefix(limit))
    for i in out.indices { out[i].line = bestLine(runs[i], words) }
    return out
  }

  /// The line of the frame at `loc` containing the most query words.
  private func bestLine(_ loc: HistoryIndex.Location, _ words: [String]) -> String {
    let recs = member(loc)
    guard loc.seq < recs.count else { return "" }
    let lines = recs[loc.seq].1.split(separator: "\n").map { History.normalize(String($0)) }
    return lines.max { a, b in words.filter(a.contains).count < words.filter(b.contains).count } ?? ""
  }

  /// All records of the gzip member holding `loc`.
  private func member(_ loc: HistoryIndex.Location) -> [(Date, String)] {
    var m = GzipRecords(url: dir.appendingPathComponent("\(loc.day).txt.gz"), from: loc.offset)
    var recs: [(Date, String)] = []
    while let r = m?.next(), m?.memberOffset == loc.offset { recs.append(r) }
    return recs
  }

  /// Bare words of an FTS5 query (not operators or column names) as quoted prefix terms; other punctuation
  /// that isn't query syntax becomes a space, as the tokenizer would treat it.
  static func prefixWords(_ s: String) -> String {
    let cleaned = String(s.map { $0.isLetter || $0.isNumber || "()*^: ".contains($0) ? $0 : " " })
    let re = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}*^])[\p{L}\p{N}]+(?![\p{L}\p{N}*(:])"#)
    var out = "", last = cleaned.startIndex
    for m in re.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
      guard let r = Range(m.range, in: cleaned) else { continue }
      let w = String(cleaned[r])
      out += cleaned[last..<r.lowerBound] + (["AND", "OR", "NOT", "NEAR"].contains(w) ? w : "\"\(w.lowercased())\"*")
      last = r.upperBound
    }
    return out + cleaned[last...]
  }

  /// Lowercased letters and digits only, as space-separated words with a space at each end, for phrase checks.
  static func words(_ s: String) -> String {
    " " + s.replacingOccurrences(of: "\u{0332}", with: "").lowercased()
      .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
  }

  /// Lowercased, underline marks and box lines dropped, runs of spaces collapsed.
  static func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{0332}", with: "").lowercased()
      .split { $0 == " " || $0 == "|" || $0 == "_" }.joined(separator: " ")
  }

  static func date(day: String) -> Date? {
    let p = day.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
  }

  /// A `@@ ` line only starts a record when the rest is a valid timestamp, so frame text survives.
  static func records(_ text: String) -> [(Date, String)] {
    var out: [(Date, [Substring])] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix(marker), let t = parseStamp(String(line.dropFirst(marker.count))) {
        out.append((t, []))
      } else if !out.isEmpty {
        out[out.count - 1].1.append(line)
      }
    }
    return out.map { t, lines in
      (t, (lines.last == "" ? lines.dropLast() : lines[...]).joined(separator: "\n"))
    }
  }

  static func day(_ t: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: t)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  private static let stampFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
  }()
  static func stamp(_ t: Date) -> String { stampFormatter.string(from: t) }
  static func parseStamp(_ s: String) -> Date? { stampFormatter.date(from: s) }
}

/// Times for `--at`/`--from`/`--to`: `now`, how long ago (`90s`, `5m`, `1h30m`, `2d`),
/// a local `HH:MM[:SS]` today, or a full ISO-8601 time.
func parseTime(_ s: String, now: Date = Date()) -> Date? {
  if let t = History.parseStamp(s) { return t }
  if s == "now" { return now }
  if let ago = parseAgo(s) { return now.addingTimeInterval(-ago) }
  let parts = s.split(separator: ":").map { Int($0) }
  guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
  return Calendar.current.date(bySettingHour: parts[0]!, minute: parts[1]!, second: parts.count == 3 ? parts[2]! : 0, of: now)
}

/// `1h30m`, `90s`, `-5m`, `2d` -> seconds; nil unless the whole string is number+unit pairs.
func parseAgo(_ s: String) -> TimeInterval? {
  var rest = Substring(s.hasPrefix("-") ? String(s.dropFirst()) : s), total = 0.0
  let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
  guard !rest.isEmpty else { return nil }
  while !rest.isEmpty {
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, let n = Double(digits), let unit = rest.dropFirst(digits.count).first,
          let mult = units[unit] else { return nil }
    total += n * mult
    rest = rest.dropFirst(digits.count + 1)
  }
  return total
}

/// One complete gzip member (zlib, windowBits 31 = gzip header and CRC32 included).
func gzip(_ data: Data) throws -> Data {
  var z = z_stream()
  guard deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                      ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
    throw NSError(domain: "ascii-screen", code: 4, userInfo: [NSLocalizedDescriptionKey: "deflateInit failed"])
  }
  defer { deflateEnd(&z) }
  var out = Data(count: Int(deflateBound(&z, uLong(data.count))) + 32)
  let status = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
      z.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
      z.avail_in = uInt(src.count)
      z.next_out = dst.bindMemory(to: Bytef.self).baseAddress
      z.avail_out = uInt(dst.count)
      return deflate(&z, Z_FINISH)
    }
  }
  guard status == Z_STREAM_END else {
    throw NSError(domain: "ascii-screen", code: 4, userInfo: [NSLocalizedDescriptionKey: "deflate failed"])
  }
  out.count = Int(z.total_out)
  return out
}

/// Decompress a multi-member gzip file.
func gunzip(_ url: URL) throws -> String {
  String(decoding: inflateMembers(try Data(contentsOf: url)), as: UTF8.self)
}

func inflateMembers(_ data: Data) -> Data {
  var members = GzipMembers(data: data), out = Data()
  while let (_, m) = members.next() { out += m }
  return out
}

/// The gzip members of a file, decoded one at a time with their byte offsets. A damaged or truncated
/// member (e.g. a crash mid-write) is dropped and decoding resumes at the next gzip header, so one bad
/// write can't hide the rest of the day. `goodEnd` is the byte after the last member decoded.
struct GzipMembers: IteratorProtocol {
  let data: Data
  private var pos: Int
  private(set) var goodEnd: Int

  init(data: Data, from: Int = 0) { self.data = data; pos = from; goodEnd = from }

  mutating func next() -> (Int, Data)? {
    var p = pos, end = goodEnd
    defer { pos = p; goodEnd = end }
    return data.withUnsafeBytes { raw -> (Int, Data)? in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
      let n = raw.count
      var chunk = [UInt8](repeating: 0, count: 1 << 16)
      while p < n {
        guard p + 2 < n, base[p] == 0x1f, base[p + 1] == 0x8b, base[p + 2] == 8 else { p += 1; continue }
        var z = z_stream()
        guard inflateInit2_(&z, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { p = n; return nil }
        var member = Data(), status = Z_OK
        z.next_in = UnsafeMutablePointer(mutating: base + p)
        z.avail_in = uInt(n - p)
        repeat {
          chunk.withUnsafeMutableBufferPointer { dst in
            z.next_out = dst.baseAddress
            z.avail_out = uInt(dst.count)
            status = inflate(&z, Z_NO_FLUSH)
            member.append(dst.baseAddress!, count: dst.count - Int(z.avail_out))
          }
        } while status == Z_OK
        let used = Int(z.total_in)
        inflateEnd(&z)
        if status == Z_STREAM_END {
          let start = p
          p += max(used, 1)
          end = p
          return (start, member)
        }
        p += 1
      }
      return nil
    }
  }
}

/// The records of one day file from byte `from` on, decoded one gzip member at a time.
struct GzipRecords: IteratorProtocol {
  private var members: GzipMembers
  private var queue: [(Date, String)] = []
  private var i = 0
  private(set) var memberOffset = -1

  init?(url: URL, from: Int = 0) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    members = GzipMembers(data: data, from: from)
  }

  mutating func next() -> (Date, String)? {
    while i == queue.count {
      guard let (offset, m) = members.next() else { return nil }
      queue = History.records(String(decoding: m, as: UTF8.self))
      i = 0
      memberOffset = offset
    }
    defer { i += 1 }
    return queue[i]
  }
}
