import XCTest
@testable import ascii_screen

final class HistoryTests: XCTestCase {
  var dir: URL!
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  func testGzipRoundTrip() throws {
    let file = dir.appendingPathComponent("x.gz")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (try gzip(Data("hello\n".utf8)) + gzip(Data("world\n".utf8))).write(to: file)
    XCTAssertEqual(try gunzip(file), "hello\nworld\n")
  }

  func testBuffersUntilFlushThenAppendsReadableGzipMembers() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, flushEvery: 300, now: { t })
    try h.record("frame one\n|  box  |")
    t += 1
    try h.record("frame two\n|  box  |")
    let file = dir.appendingPathComponent("\(History.day(t)).txt.gz")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing written before a flush")
    try h.flush()
    t += 1
    try h.record("frame three")
    try h.flush()
    let records = History.records(try gunzip(file))
    XCTAssertEqual(records.map(\.1), ["frame one\n|  box  |", "frame two\n|  box  |", "frame three"])
    XCTAssertEqual(records.map { $0.0.timeIntervalSince1970 }, [1_800_000_000, 1_800_000_001, 1_800_000_002])
  }

  func testFlushesAutomaticallyAfterInterval() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, flushEvery: 300, now: { t })
    try h.record("a")
    t += 301
    try h.record("b")
    let records = History.records(try gunzip(dir.appendingPathComponent("\(History.day(t)).txt.gz")))
    XCTAssertEqual(records.map(\.1), ["a", "b"])
  }

  func testTimerFlushesWhenScreenGoesQuiet() throws {
    let h = History(dir: dir, flushEvery: 0.2)
    try h.record("only change")
    Thread.sleep(forTimeInterval: 0.6)
    let file = dir.appendingPathComponent("\(History.day(Date())).txt.gz")
    XCTAssertEqual(History.records(try gunzip(file)).map(\.1), ["only change"])
  }

  func testFrameAtReturnsLastFrameAtOrBeforeTimeAcrossMidnight() throws {
    let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    var t = midnight - 10
    let h = History(dir: dir, now: { t })
    try h.record("before midnight")
    t = midnight + 60
    try h.record("after midnight")
    try h.flush()
    XCTAssertEqual(h.frame(at: midnight + 30)?.1, "before midnight")
    XCTAssertEqual(h.frame(at: midnight + 61)?.1, "after midnight")
    XCTAssertNil(h.frame(at: midnight - 20))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(History.day(midnight - 10)).txt.gz").path))
  }

  func testPrunesOldDays() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, keepDays: 2, now: { t })
    try h.record("old")
    try h.flush()
    let old = dir.appendingPathComponent("\(History.day(t)).txt.gz")
    t += 3 * 86400
    try h.record("new")
    try h.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
  }

  func testFramesStartingWithMarkerTextSurvive() throws {
    let text = "x\n@@ not a stamp\ny"
    XCTAssertEqual(History.records("@@ \(History.stamp(Date(timeIntervalSince1970: 0)))\n\(text)\n").map(\.1), [text])
  }

  func testParseTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t = parseTime("14:05", now: now)!
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: t)
    XCTAssertEqual([c.hour, c.minute, c.second], [14, 5, 0])
    XCTAssertEqual(parseTime(History.stamp(now))?.timeIntervalSince1970, 1_800_000_000)
    XCTAssertNil(parseTime("nonsense"))
  }

  func testRelativeTimes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (s, ago) in [("1m", 60.0), ("90s", 90), ("-5m", 300), ("1h30m", 5400), ("2d", 172_800), ("now", 0)] {
      XCTAssertEqual(parseTime(s, now: now)?.timeIntervalSince1970, 1_800_000_000 - ago, s)
    }
    for s in ["", "-", "5", "m", "5x", "1h30", "5 m", "1.5m"] { XCTAssertNil(parseTime(s, now: now), s) }
  }

  func testFramesBetweenStartWithFrameAlreadyOnScreen() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, flushEvery: 300, now: { t })
    for name in ["a", "b", "c", "d"] { try h.record(name); t += 60 }
    try h.flush()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let got = Array(IteratorSequence(h.frames(from: start + 90, to: start + 180)))
    XCTAssertEqual(got.map(\.1), ["b", "c", "d"])
  }

  func testPlaybackDelayScalesAndCapsGaps() {
    let t = Date(timeIntervalSince1970: 0)
    var p = Playback(frames: [(t, "a"), (t + 5, "b"), (t + 605, "c")], speed: 10, maxGap: 2)
    XCTAssertEqual(p.delay(after: 0), 0.5, accuracy: 1e-9)
    XCTAssertEqual(p.delay(after: 1), 2)
    XCTAssertEqual(p.delay(after: 2), 0)
  }

  func testPlaybackKeys() {
    XCTAssertEqual(Playback.key([0x20]), .pause)
    XCTAssertEqual(Playback.key([0x1b, 0x5b, 0x43]), .next)
    XCTAssertEqual(Playback.key([0x1b, 0x5b, 0x44]), .previous)
    XCTAssertEqual(Playback.key([0x1b, 0x5b, 0x41]), .faster)
    XCTAssertEqual(Playback.key([0x2d]), .slower)
    XCTAssertEqual(Playback.key([0x03]), .quit)
    XCTAssertEqual(Playback.key([0x78]), .other)
    XCTAssertEqual(Playback.keys([0x1b, 0x5b, 0x44, 0x1b, 0x5b, 0x44, 0x71]), [.previous, .previous, .quit])
  }

  func testDamagedMemberDoesNotHideTheRestOfTheDay() throws {
    func member(_ s: String) throws -> Data { try gzip(Data(s.utf8)) }
    let a = try member("@@ 2026-10-27T10:00:00Z\nA\n"), b = try member("@@ 2026-10-27T10:00:10Z\nB\n")
    let c = try member("@@ 2026-10-27T10:00:20Z\nC\n"), d = try member("@@ 2026-10-27T10:00:30Z\nD\n")
    var corrupt = c
    corrupt[corrupt.count / 2] ^= 0xFF
    let text = String(decoding: inflateMembers(a + b + corrupt + d + c.prefix(c.count - 4)), as: UTF8.self)
    XCTAssertEqual(History.records(text).map(\.1), ["A", "B", "D"])
  }

  func testHistoryFilesArePrivate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("h")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let h = History(dir: dir)
    try h.record("secret")
    try h.flush()
    let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)[0]
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
  }

  func testPlaybackDelayNeverNegativeWhenClockMovesBack() {
    let t = Date()
    var p = Playback(frames: [(t, "a"), (t.addingTimeInterval(-60), "b")], speed: 1, maxGap: 2)
    XCTAssertEqual(p.delay(after: 0), 0)
  }

  func testFramesAreFoundAcrossMembersAndDaysWithAndWithoutTheIndex() throws {
    let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    var t = midnight - 30
    let h = History(dir: dir, flushEvery: 300, now: { t })
    for name in ["a", "b", "c", "d", "e"] { try h.record(name); try h.flush(); t += 20 }
    for indexed in [true, false] {
      if !indexed { try FileManager.default.removeItem(at: dir.appendingPathComponent("index.sqlite")) }
      let reader = History(dir: dir)
      XCTAssertEqual(Array(IteratorSequence(reader.frames(from: midnight - 5, to: midnight + 35))).map(\.1), ["b", "c", "d"])
      XCTAssertEqual(Array(IteratorSequence(reader.frames(from: midnight + 10, to: midnight + 10))).map(\.1), ["c"])
      XCTAssertEqual(reader.frame(at: midnight + 69)?.1, "e")
      XCTAssertNil(reader.frame(at: midnight - 31))
    }
  }

  func testSearchMatchesWordsPrefixesAndFTSSyntaxAndMergesRuns() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, flushEvery: 300, now: { t })
    for frame in ["|  Invoice   #42  |", "Invoices  #42 due", "nothing here", "42 cats and an invoice"] {
      try h.record(frame); try h.flush(); t += 10
    }
    t += 600
    try h.record("I̲n̲v̲o̲i̲c̲e̲ #42 again"); try h.flush()
    func find(_ q: String) throws -> [History.Match] { try History(dir: dir).search(q, from: .distantPast, to: .distantFuture, limit: 10) }
    XCTAssertEqual(try find("invoice 42").map(\.frames), [2, 2])
    XCTAssertEqual(try find("invoice 42").map(\.line), ["invoice #42 again", "invoices #42 due"])
    XCTAssertEqual(try find("\"invoice 42\"").map(\.frames), [1, 1])
    XCTAssertEqual(try find("\"42 cats\" invoice").map(\.frames), [1])
    XCTAssertEqual(try find("\"cats 42\"").count, 0)
    XCTAssertEqual(try find("invoice NOT \"42 cats\"").map(\.frames), [1, 2])
    XCTAssertEqual(History.prefixWords("inv OR (due NOT x*) text:cat ^a 42.5"), "\"inv\"* OR (\"due\"* NOT x*) text:\"cat\"* ^a \"42\"* \"5\"*")
    XCTAssertEqual(try find("cats OR due").map(\.frames), [1, 1])
    XCTAssertEqual(try find("invo* NOT again").map(\.frames), [1, 2])
    XCTAssertEqual(try History(dir: dir).search("invoice", from: .distantPast, to: .distantFuture, limit: 1).count, 1)
    XCTAssertTrue(try find("zebra").isEmpty)
    XCTAssertThrowsError(try find("\"unbalanced"))
  }

  func testSearchMergesRunsAcrossDaysIndexedOutOfOrder() throws {
    let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    var t = midnight - 30
    let h = History(dir: dir, flushEvery: 300, now: { t })
    try h.record("alpha one"); try h.flush()
    t = midnight + 30
    try h.record("alpha two"); try h.flush()
    for f in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    let fresh = try HistoryIndex(dir: dir)
    try fresh.catchUp(day: History.day(t))
    try fresh.catchUp()
    t += 30
    let h2 = History(dir: dir, flushEvery: 300, now: { t })
    try h2.record("alpha three"); try h2.flush()
    let runs = try History(dir: dir).search("alpha", from: .distantPast, to: .distantFuture, limit: 10)
    XCTAssertEqual(runs.map(\.frames), [3])
    XCTAssertEqual(runs.first?.line, "alpha three")
  }

  func testIndexForgetsPrunedDaysAndCatchesUpOnAppends() throws {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    let h = History(dir: dir, keepDays: 2, now: { t })
    try h.record("old words"); try h.flush()
    t += 3 * 86400
    try h.record("new words"); try h.flush()
    XCTAssertTrue(try History(dir: dir).search("old", from: .distantPast, to: .distantFuture, limit: 5).isEmpty)
    let file = dir.appendingPathComponent("\(History.day(t)).txt.gz")
    let fh = try FileHandle(forWritingTo: file)
    try fh.seekToEnd()
    try fh.write(contentsOf: gzip(Data("@@ \(History.stamp(t + 5))\nappended elsewhere\n".utf8)))
    try fh.close()
    XCTAssertEqual(try History(dir: dir).search("appended", from: .distantPast, to: .distantFuture, limit: 5).count, 1)
  }

  func testPlaybackReadsLazilyAndKeepsABoundedWindow() {
    var pulled = 0
    let t = Date(timeIntervalSince1970: 0)
    let frames = AnyIterator<(Date, String)> { pulled += 1; return pulled <= 5000 ? (t + Double(pulled), "f\(pulled)") : nil }
    var p = Playback(frames: IteratorSequence(frames), speed: 1, maxGap: 2)
    XCTAssertEqual(p.frame(0)?.1, "f1")
    XCTAssertEqual(p.delay(after: 0), 1)
    XCTAssertEqual(pulled, 2)
    XCTAssertEqual(p.frame(3000)?.1, "f3001")
    XCTAssertNil(p.frame(0), "old frames are dropped")
    XCTAssertEqual(p.first, 3001 - Playback.keepBack)
    XCTAssertFalse(p.isLast(3000))
    XCTAssertTrue(p.isLast(4999))
  }
}
