import CoreVideo
import XCTest
@testable import ascii_screen

final class PipelineTests: XCTestCase {
  private func frame(_ points: [(Int, Int)] = [], width: Int = 800, height: Int = 600) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    memset(base, 255, stride * height)
    for (x, y) in points { memset(base + y * stride + x * 4, 0, 4) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  func testIdenticalFrameSkipsOCRWhenEveryChangedFrameRequiresFullOCR() {
    var opts = Options()
    opts.fullEvery = 0
    var calls = 0
    let p = Pipeline(opts) { _, rois in calls += 1; return rois.map { _ in [] } }
    XCTAssertTrue(p.process(frame()))
    XCTAssertFalse(p.process(frame()))
    XCTAssertEqual(calls, 1)
  }

  func testRefreshThresholdOnlyAppliesToChangedFrames() {
    var opts = Options()
    opts.fullEvery = 1
    var requests: [[CGRect]] = []
    let p = Pipeline(opts) { _, rois in requests.append(rois); return rois.map { _ in [] } }
    XCTAssertTrue(p.process(frame()))
    XCTAssertTrue(p.process(frame([(200, 200)])))
    XCTAssertFalse(p.process(frame([(200, 200)])))
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(p.process(frame([(210, 200)])))
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests.last, [CGRect(x: 0, y: 0, width: 1, height: 1)])
  }

  func testCacheReplacementRemovesDeletedTextButKeepsUnchangedText() {
    let removed = Obs(text: "old", x: 0.25, y: 0.6, w: 0.15, h: 0.08)
    let kept = Obs(text: "footer", x: 0.7, y: 0.1, w: 0.2, h: 0.06)
    var calls = 0
    let p = Pipeline(Options()) { _, rois in
      calls += 1
      return calls == 1 ? [[removed, kept]] : rois.map { _ in [] }
    }
    p.process(frame())
    p.process(frame([(220, 220)]))
    XCTAssertEqual(p.obs.map(\.text), ["footer"])
  }

  func testRegionsGrowToCoverWholeCachedTextBoxesAndMerge() {
    let words = [
      Obs(text: "first", x: 0.15, y: 0.60, w: 0.2, h: 0.08),
      Obs(text: "second", x: 0.34, y: 0.60, w: 0.2, h: 0.08),
      Obs(text: "third", x: 0.53, y: 0.60, w: 0.2, h: 0.08),
    ]
    var requests: [[CGRect]] = []
    let p = Pipeline(Options()) { _, rois in
      requests.append(rois)
      return requests.count == 1 ? [words] : rois.map { _ in [] }
    }
    p.process(frame())
    p.process(frame([(150, 220), (550, 220)]))
    XCTAssertEqual(requests.last?.count, 1)
    for o in words {
      XCTAssertTrue(requests.last![0].contains(CGRect(x: o.x, y: o.y, width: o.w, height: o.h)))
    }
  }

  func testDimensionChangeForcesFullOCR() {
    var requests: [[CGRect]] = []
    let p = Pipeline(Options()) { _, rois in requests.append(rois); return rois.map { _ in [] } }
    p.process(frame())
    p.process(frame(width: 801))
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last, [CGRect(x: 0, y: 0, width: 1, height: 1)])
  }

  func testFractionalTextBoundsDoNotStallRegionExpansion() {
    let words = [
      Obs(text: "first", x: 0.17221066628595877, y: 0.6548700442538966,
          w: 0.34429685337881527, h: 0.05844486402975076),
      Obs(text: "second", x: 0.119741165141257, y: 0.5580873193633952,
          w: 0.33150544346634325, h: 0.04135090662535894),
    ]
    var opts = Options()
    opts.atlas = false
    var requests: [[CGRect]] = []
    let p = Pipeline(opts) { _, rois in
      requests.append(rois)
      return requests.count == 1 ? [words] : rois.map { _ in [] }
    }
    p.process(frame())
    let changed = frame([(220, 220)])
    let finished = expectation(description: "Region expansion terminates")
    DispatchQueue.global().async {
      p.process(changed)
      finished.fulfill()
    }
    let result = XCTWaiter.wait(for: [finished], timeout: 1)
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last?.count, 1)
    for o in words {
      XCTAssertTrue(requests.last![0].contains(CGRect(x: o.x, y: o.y, width: o.w, height: o.h)))
    }
  }

  func testSeparateChangedRegionsShareOneOCRCall() {
    for atlas in [true, false] {
      var opts = Options()
      opts.atlas = atlas
      var requests: [[CGRect]] = []
      let p = Pipeline(opts) { _, rois in requests.append(rois); return rois.map { _ in [] } }
      p.process(frame())
      p.process(frame([(100, 100), (700, 500)]))
      XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(requests.last?.count, atlas ? 1 : 2)
    }
  }

  func testNonFiniteCachedBoxesNeitherCrashNorHang() {
    let bad = [Obs(text: "nan", x: .nan, y: 0.5, w: 0.1, h: 0.1), Obs(text: "inf", x: 0.2, y: 0.5, w: .infinity, h: 0.1),
               Obs(text: "ok", x: 0.2, y: 0.5, w: 0.1, h: 0.05)]
    var calls = 0
    let p = Pipeline(Options()) { _, rois in calls += 1; return calls == 1 ? [bad] : rois.map { _ in [] } }
    p.process(frame())
    XCTAssertTrue(p.process(frame([(170, 290)])))
    XCTAssertEqual(calls, 2)
  }

  func testAtlasWithOnlyEmptyRegionsReturnsNothing() {
    let p = Pipeline(Options()) { _, rois in rois.map { _ in [] } }
    XCTAssertEqual(p.ocr.recognizeAtlas(frame(), [.zero, CGRect(x: 5, y: 5, width: 0, height: 9)]).count, 0)
  }

  /// A page of "text": rows of pseudo-random pixels from document row `top + y`, with a fixed header on top.
  private func page(scrolledBy top: Int, width: Int = 800, height: Int = 600, header: Int = 60) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
      let doc = y < header ? -1 - y : top + y
      for x in 0..<width {
        var v = UInt32(truncatingIfNeeded: doc &* 73_856_093 ^ x &* 19_349_663)
        v ^= v >> 13; v = v &* 0x5bd1e995; v ^= v >> 15
        memset(base + y * stride + x * 4, Int32(v & 0xFF), 4)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  func testScrollMovesCachedTextAndOnlyReadsTheRevealedStrip() {
    let H = 600.0
    let line = Obs(text: "kept", x: 0.1, y: 0.5, w: 0.3, h: 0.04) // pixel rows 276-300
    var opts = Options()
    opts.atlas = false
    var requests: [[CGRect]] = []
    let p = Pipeline(opts) { _, rois in
      requests.append(rois)
      return requests.count == 1 ? [[line]] : rois.map { _ in [] }
    }
    p.process(page(scrolledBy: 0))
    XCTAssertTrue(p.process(page(scrolledBy: 40)))
    XCTAssertEqual(requests.count, 2)
    let read = requests[1].reduce(0.0) { $0 + $1.width * $1.height }
    XCTAssertLessThan(read, 0.2, "only the newly revealed rows should be read, not the whole screen")
    XCTAssertTrue(requests[1].allSatisfy { $0.minY < 0.2 }, "the revealed strip is at the bottom")
    XCTAssertEqual(p.obs.map(\.text), ["kept"])
    XCTAssertEqual(p.obs[0].y, line.y + 40 / H, accuracy: 1e-9)
  }

  func testInPlaceChangeIsNotMistakenForScroll() {
    let p = Pipeline(Options()) { _, rois in rois.map { _ in [] } }
    let frames = [page(scrolledBy: 0), page(scrolledBy: 0, header: 100), page(scrolledBy: -25)]
    frames.forEach { CVPixelBufferLockBaseAddress($0, .readOnly) }
    defer { frames.forEach { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }
    let bm = frames.map {
      Bitmap(base: CVPixelBufferGetBaseAddress($0)!.assumingMemoryBound(to: UInt8.self), width: 800, height: 600,
             rowBytes: CVPixelBufferGetBytesPerRow($0))
    }
    XCTAssertNil(p.scrollShift(bm[0], bm[1]))
    XCTAssertEqual(p.scrollShift(bm[0], bm[2]), -25)
  }
}
