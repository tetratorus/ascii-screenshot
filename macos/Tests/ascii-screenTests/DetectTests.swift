import XCTest
@testable import ascii_screen

/// BGRA test image; colours are (blue, green, red).
private struct Image {
  let width: Int, height: Int
  var px: [UInt8]
  init(_ width: Int, _ height: Int, _ c: (UInt8, UInt8, UInt8) = (255, 255, 255)) {
    self.width = width; self.height = height
    px = Array(repeating: 255, count: width * height * 4)
    fill(0..<width, 0..<height, c)
  }
  mutating func fill(_ xs: Range<Int>, _ ys: Range<Int>, _ c: (UInt8, UInt8, UInt8)) {
    for y in ys { for x in xs { set(x, y, c) } }
  }
  mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
    let i = (y * width + x) * 4
    px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
  }
}

private func gray(_ v: UInt8) -> (UInt8, UInt8, UInt8) { (v, v, v) }

final class DetectTests: XCTestCase {
  /// Detected lines without the four image borders, which are always appended last.
  private func detect(_ img: Image, file: StaticString = #filePath, line: UInt = #line) -> [DLine] {
    let lines = img.px.withUnsafeBufferPointer {
      detectLines(Bitmap(base: $0.baseAddress!, width: img.width, height: img.height, rowBytes: img.width * 4))
    }
    let frame = lines.suffix(4).map { [$0.vertical ? 1 : 0, $0.x, $0.y, $0.w, $0.h] as [Double] }
    XCTAssertEqual(frame, [[1, 0, 0, 0, 1], [1, 1, 0, 0, 1], [0, 0, 0, 1, 0], [0, 0, 1, 1, 0]], file: file, line: line)
    return Array(lines.dropLast(4))
  }

  private func assertBoundary(_ lines: [DLine], vertical: Bool, at position: Double, from start: Double, to end: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(lines.contains { l in
      let (along, across, length) = vertical ? (l.y, l.x, l.h) : (l.x, l.y, l.w)
      return l.vertical == vertical && abs(across - position) < 0.015
        && along <= start + 0.015 && along + length >= end - 0.015
    }, "\(vertical ? "|" : "_") at \(position) from \(start) to \(end) not in \(lines)", file: file, line: line)
  }

  func testFilledRegionsWithoutBorderStrokes() {
    for s in [1, 2] {
      var img = Image(600 * s, 400 * s)
      img.fill(0..<150 * s, 0..<400 * s, (245, 247, 249))
      img.fill(150 * s..<600 * s, 0..<80 * s, (50, 80, 110))
      let lines = detect(img)
      assertBoundary(lines, vertical: true, at: 0.25, from: 0, to: 1)
      assertBoundary(lines, vertical: false, at: 0.2, from: 0.25, to: 1)
    }
  }

  func testFaintCardEdgesAndCellFills() {
    var img = Image(600, 400)
    img.fill(100..<500, 80..<320, (250, 248, 246))
    img.fill(300..<500, 200..<320, (200, 210, 220))
    let lines = detect(img)
    for x in [100.0 / 600, 500.0 / 600] { assertBoundary(lines, vertical: true, at: x, from: 0.2, to: 0.8) }
    for y in [0.2, 0.8] { assertBoundary(lines, vertical: false, at: y, from: 100.0 / 600, to: 500.0 / 600) }
    assertBoundary(lines, vertical: true, at: 0.5, from: 0.5, to: 0.8)
  }

  func testThinRulesAreMergedOnce() {
    var img = Image(600, 400)
    img.fill(50..<550, 100..<102, gray(100))
    img.fill(300..<302, 40..<360, gray(100))
    let lines = detect(img)
    assertBoundary(lines, vertical: false, at: 0.25, from: 50.0 / 600, to: 550.0 / 600)
    assertBoundary(lines, vertical: true, at: 0.5, from: 0.1, to: 0.9)
    XCTAssertEqual(lines.count, 2)
  }

  func testTextureAndFaintBackgroundStripesAreNotPanels() {
    var texture = Image(600, 400)
    var seed: UInt64 = 17
    for i in texture.px.indices where i % 4 != 3 {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      texture.px[i] = UInt8(truncatingIfNeeded: seed >> 56)
    }
    XCTAssertEqual(detect(texture).count, 0)
    var stripes = Image(600, 400, gray(70))
    for x in stride(from: 5, to: 600, by: 10) { stripes.fill(x..<x + 1, 0..<400, gray(76)) }
    XCTAssertEqual(detect(stripes).count, 0)
  }

  func testTableWithDifferentlyColouredCells() {
    var img = Image(600, 400)
    img.fill(60..<300, 60..<340, (230, 240, 250))
    img.fill(300..<540, 60..<340, (250, 230, 240))
    img.fill(60..<540, 198..<200, gray(80))
    assertBoundary(detect(img), vertical: false, at: 0.5, from: 0.1, to: 0.9)
  }

  func testBlankAndSmallImagesKeepOnlyFrame() {
    for (w, h) in [(600, 400), (1, 1), (10, 10)] { XCTAssertEqual(detect(Image(w, h)).count, 0) }
  }
}
