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

  init(dir: URL, flushEvery: TimeInterval = 10, keepDays: Int = 14, now: @escaping () -> Date = Date.init) {
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
    }
  }

  /// The frame that was on screen at `time`: the last record at or before it.
  func frame(at time: Date) throws -> (Date, String)? {
    for day in [History.day(time), History.day(time.addingTimeInterval(-86400))] {
      let url = dir.appendingPathComponent("\(day).txt.gz")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      if let hit = History.records(try gunzip(url)).last(where: { $0.0 <= time }) { return hit }
    }
    return nil
  }

  /// Every frame recorded between `from` and `to`, starting with the one already on screen at `from`.
  func frames(from: Date, to: Date) throws -> [(Date, String)] {
    var out: [(Date, String)] = []
    if let first = try frame(at: from), first.0 < from { out.append(first) }
    var d = Calendar.current.startOfDay(for: from)
    while d <= to {
      let url = dir.appendingPathComponent("\(History.day(d)).txt.gz")
      if FileManager.default.fileExists(atPath: url.path) {
        out += History.records(try gunzip(url)).filter { $0.0 >= from && $0.0 <= to }
      }
      d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
    }
    return out
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

/// `--at` accepts a full ISO-8601 time or a local `HH:MM[:SS]` today.
func parseTime(_ s: String, now: Date = Date()) -> Date? {
  if let t = History.parseStamp(s) { return t }
  let parts = s.split(separator: ":").map { Int($0) }
  guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
  return Calendar.current.date(bySettingHour: parts[0]!, minute: parts[1]!, second: parts.count == 3 ? parts[2]! : 0, of: now)
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

/// Decode each gzip member in turn. A damaged or truncated member (e.g. a crash mid-write) is dropped
/// and decoding resumes at the next gzip header, so one bad write can't hide the rest of the day.
func inflateMembers(_ data: Data) -> Data {
  let bytes = [UInt8](data)
  var out = Data(), pos = 0
  let isHeader = { (i: Int) in i + 2 < bytes.count && bytes[i] == 0x1f && bytes[i + 1] == 0x8b && bytes[i + 2] == 8 }
  var chunk = [UInt8](repeating: 0, count: 1 << 16)
  while pos < bytes.count {
    guard isHeader(pos) else { pos += 1; continue }
    var z = z_stream()
    guard inflateInit2_(&z, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { break }
    var member = Data(), status = Z_OK
    bytes.withUnsafeBufferPointer { src in
      z.next_in = UnsafeMutablePointer(mutating: src.baseAddress! + pos)
      z.avail_in = uInt(src.count - pos)
      repeat {
        chunk.withUnsafeMutableBufferPointer { dst in
          z.next_out = dst.baseAddress
          z.avail_out = uInt(dst.count)
          status = inflate(&z, Z_NO_FLUSH)
          member.append(dst.baseAddress!, count: dst.count - Int(z.avail_out))
        }
      } while status == Z_OK
    }
    let used = Int(z.total_in)
    inflateEnd(&z)
    if status == Z_STREAM_END { out += member; pos += max(used, 1) } else { pos += 1 }
  }
  return out
}
