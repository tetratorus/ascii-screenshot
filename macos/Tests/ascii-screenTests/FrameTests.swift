import XCTest
@testable import ascii_screen

final class FrameTests: XCTestCase {
  let sample = Frame(width: 1600, height: 1000,
                     obs: [Obs(text: "Inbox (3)", x: 0.05, y: 0.8, w: 0.1, h: 0.03),
                           Obs(text: "here-is-a-very-long-text-doesnt-fit-inside", x: 0.05, y: 0.5, w: 0.3, h: 0.03),
                           Obs(text: "测试 test", x: 0.6, y: 0.5, w: 0.1, h: 0.03)],
                     lines: [DLine(vertical: true, x: 0.4, y: 0.1, w: 0, h: 0.8),
                             DLine(vertical: false, x: 0, y: 0.6, w: 1, h: 0)],
                     cursor: CGPoint(x: 0.5, y: 0.25))

  func testEncodedFrameDrawsTheSameAtAnyGrid() throws {
    let live = Frame(width: 1600, height: 1000, obs: sample.obs.map { var o = $0; o.y += 0.0000123; o.x -= 0.0000049; return o },
                     lines: sample.lines, cursor: sample.cursor).quantized()
    let saved = live.encode()
    let back = try XCTUnwrap(Frame.decode(saved))
    XCTAssertEqual(back.encode(), saved)
    for (w, h) in [(160, nil), (240, nil), (80, 24), (400, 200), (37, 11)] as [(Int, Int?)] {
      XCTAssertEqual(back.render(columns: w, rows: h), live.render(columns: w, rows: h))
    }
  }

  func testBiggerGridKeepsTextThatASmallOneCuts() {
    XCTAssertTrue(sample.render(columns: 40).contains("…"))
    XCTAssertFalse(sample.render(columns: 40).contains("here-is-a-very-long-text-doesnt-fit-inside"))
    XCTAssertTrue(sample.render(columns: 240).contains("here-is-a-very-long-text-doesnt-fit-inside"))
  }

  func testGridSizeAndOldRecords() {
    let out = History.display(sample.encode(), columns: 100, rows: 30).split(separator: "\n", omittingEmptySubsequences: false)
    XCTAssertEqual(out.count, 30)
    XCTAssertTrue(out.allSatisfy { $0.reduce(0) { $0 + columns($1) } == 100 })
    XCTAssertEqual(History.display(sample.encode(), columns: 100, rows: nil).split(separator: "\n", omittingEmptySubsequences: false).count, 31)
    XCTAssertEqual(History.display("| old drawn frame |", columns: 100, rows: 30), "| old drawn frame |")
    XCTAssertNil(Frame.decode("______\n| text |"))
  }

  func testTextIsEveryBoxTopToBottomInFull() {
    XCTAssertEqual(sample.text, "Inbox (3)\nhere-is-a-very-long-text-doesnt-fit-inside\n测试 test")
    XCTAssertEqual(History.text("I̲n̲v̲o̲i̲c̲e̲ #42"), "Invoice #42")
  }

  func testPlaybackFitsEachRecordedOrientation() throws {
    let sizes = [(1216, 2656), (2656, 1216), (1216, 2656)]
    let frames = sizes.enumerated().map { index, size in
      (Date(timeIntervalSince1970: Double(index)),
       Frame(width: size.0, height: size.1, obs: [], lines: [], cursor: nil).encode())
    }
    var player = Playback(frames: frames, speed: 1, maxGap: 0) { body, _ in
      History.display(body, columns: 120, rows: 39, fit: true)
    }
    for (i, expected) in [(0, (35, 38)), (1, (120, 27)), (2, (35, 38))] {
      let rows = try XCTUnwrap(player.shown(i)).split(separator: "\n", omittingEmptySubsequences: false)
      XCTAssertEqual(rows.count, expected.1)
      XCTAssertTrue(rows.allSatisfy { $0.count == expected.0 })
    }
    XCTAssertEqual(History.display("old frame", columns: 120, rows: 39, fit: true), "old frame")
  }

  func testCellAspectFromTerminalMetricsAndFit() {
    XCTAssertEqual(Frame.cellAspect(cols: 100, rows: 40, xpixel: 720, ypixel: 680), 2.3611, accuracy: 0.001)
    XCTAssertEqual(Frame.cellAspect(cols: 100, rows: 40, xpixel: 0, ypixel: 0), Frame.defaultCellAspect)
    XCTAssertEqual(Frame.cellAspect(cols: 100, rows: 40, xpixel: 1000, ypixel: 100), Frame.defaultCellAspect)
    let portrait = Frame(width: 1206, height: 2622, obs: [], lines: [], cursor: nil)
    let monaco = portrait.render(columns: 120, rows: 40, fit: true, cellAspect: 2.36).split(separator: "\n")
    let fallback = portrait.render(columns: 120, rows: 40, fit: true, cellAspect: 2.0).split(separator: "\n")
    XCTAssertGreaterThan(monaco[0].count, fallback[0].count)
  }

  func testSearchFindsTextACrampedGridWouldHaveCut() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let h = History(dir: dir, flushEvery: 300)
    try h.record(sample.encode()); try h.flush()
    let m = try History(dir: dir).search("doesnt fit", from: .distantPast, to: .distantFuture, limit: 5)
    XCTAssertEqual(m.map(\.line), ["here-is-a-very-long-text-doesnt-fit-inside"])
    XCTAssertEqual(try History(dir: dir).search("\"long text\"", from: .distantPast, to: .distantFuture, limit: 5).count, 1)
  }
}
