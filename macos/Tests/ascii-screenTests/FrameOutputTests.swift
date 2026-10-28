import XCTest
@testable import ascii_screen

final class FrameOutputTests: XCTestCase {
  func testWritesOnlyChangedFrames() throws {
    var written: [String] = []
    let output = FrameOutput { written.append($0) }
    XCTAssertTrue(try output.emit("first"))
    XCTAssertFalse(try output.emit("first"))
    XCTAssertTrue(try output.emit("second"))
    XCTAssertEqual(written, ["first", "second"])
  }

  func testFailedWritesAreReportedAndNotCached() throws {
    enum Failure: Error { case diskFull }
    var attempts = 0
    let output = FrameOutput { _ in
      attempts += 1
      if attempts == 1 { throw Failure.diskFull }
    }
    XCTAssertThrowsError(try output.emit("frame"))
    XCTAssertTrue(try output.emit("frame"))
    XCTAssertFalse(try output.emit("frame"))
    XCTAssertEqual(attempts, 2)
  }

  func testEmptyFirstFrameIsWritten() throws {
    var written: [String] = []
    let output = FrameOutput { written.append($0) }
    XCTAssertTrue(try output.emit(""))
    XCTAssertEqual(written, [""])
  }

  func testSettleKeepsOnlyNewestFrameUntilStillOrMaxLag() {
    let s = Settle<Int>(maxLag: 5), t = Date()
    XCTAssertNil(s.offer(1, now: t))
    XCTAssertNil(s.offer(2, now: t + 1))
    XCTAssertEqual(s.take(), 2)
    XCTAssertNil(s.take())
    XCTAssertNil(s.offer(3, now: t + 10))
    XCTAssertNil(s.offer(4, now: t + 14))
    XCTAssertEqual(s.offer(5, now: t + 15), 5)
    XCTAssertNil(s.take())
    XCTAssertEqual(Settle<Int>(maxLag: 0).offer(7), 7)
  }
}
