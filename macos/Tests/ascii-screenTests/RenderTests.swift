import XCTest
@testable import ascii_screen

private let underline = "\u{0332}"
private let pointer = "\u{1F446}"

private func line(_ text: String, _ x: Double, _ y: Double, w: Double = 0, h: Double = 0) -> DLine {
  DLine(vertical: text == "|", x: x, y: y, w: w, h: h)
}
private func rows(_ s: String) -> [String] { s.components(separatedBy: "\n") }
/// Unicode scalars of a row, so combining underlines and the pointer each count as one entry.
private func cols(_ s: String) -> [String] { s.unicodeScalars.map(String.init) }
private func underlined(_ s: String) -> String { s.map { "\($0)\(underline)" }.joined() }

final class RenderTests: XCTestCase {
  func testIntersectionsPreserveBothOrientationsInEitherOrder() {
    let v = line("|", 0.5, 0, h: 1), hz = line("_", 0, 0.5, w: 1)
    for lines in [[v, hz], [hz, v], [v, hz, v, hz]] {
      let r = addLines("__________\n" + String(repeating: String(repeating: " ", count: 10) + "\n", count: 6) + "__________",
                       lines, 10, 6)
      let rs = rows(r.finalText)
      XCTAssertEqual(rs[3], "_____|____")
      XCTAssertEqual(rows(r.linesText)[3], "_____|____")
      XCTAssertTrue(rs.allSatisfy { cols($0)[5] == "|" })
      XCTAssertTrue(rs.allSatisfy { cols($0.replacingOccurrences(of: underline, with: "")).count == 10 })
      XCTAssertFalse(r.finalText.contains("+"))
    }
  }

  func testIntersectionOverwritesTextWithoutShiftingFollowingColumns() {
    let original = "__________\nABCDEFGHIJ\nABCDEFGHIJ\nABCDEFGHIJ\n__________"
    let r = addLines(original, [line("|", 0.4, 0, h: 1), line("_", 0, 0.5, w: 1)], 10, 3)
    XCTAssertEqual(r.originalText, original)
    XCTAssertEqual(rows(r.finalText), ["ABCD|FGHIJ", underlined("ABCD") + "|" + underlined("FGHIJ"), "ABCD|FGHIJ"])
  }

  func testBoxHasBlankTopCornersAndBarBottomCorners() {
    // Edges as detected: verticals start a row above the top edge and the
    // horizontals overshoot the right vertical by a cell.
    let box = [line("_", 0.2, 0.21, w: 0.62), line("_", 0.2, 0.81, w: 0.62),
               line("|", 0.2, 0.1, h: 0.72), line("|", 0.8, 0.1, h: 0.72)]
    let r = addLines("__________\n" + String(repeating: String(repeating: " ", count: 10) + "\n", count: 5) + "__________",
                     box, 10, 5)
    XCTAssertEqual(rows(r.finalText), ["          ", "   _____  ", "  |     | ", "  |     | ", "  |_____| "])
  }

  func testVerticalHangingFromARuleStartsBelowIt() {
    let r = addLines("_____\n" + String(repeating: "     \n", count: 3) + "_____",
                     [line("_", 0, 0.1, w: 1), line("|", 0.5, 0.1, h: 0.9)], 5, 3)
    XCTAssertEqual(rows(r.finalText), ["_____", "  |  ", "  |  "])
  }

  func testOCRPlusSignIsPreserved() {
    XCTAssertEqual(addLines("___\nA+B\n___", [], 3, 1).finalText, "A+B")
  }

  func testVerticalBoundariesTakePrecedenceOverCollidingText() {
    let original = "__________\nABCDEFGHIJ\nABCDEFGHIJ\n__________"
    let r = addLines(original, [line("|", 0.4, 0, h: 1)], 10, 2)
    XCTAssertEqual(r.originalText, original)
    XCTAssertEqual(r.finalText, "ABCD|FGHIJ\nABCD|FGHIJ")
  }

  func testHorizontalRuleKeepsTextWithCombiningUnderline() {
    XCTAssertEqual(addLines("____\nText\n____", [line("_", 0, 0, w: 1)], 4, 1).finalText, underlined("Text"))
  }

  func testOCRGlyphEdgesAreRemovedButLongStructuralEdgesRemain() {
    let text = [Obs(text: "Tables", x: 0.3, y: 0.6, w: 0.4, h: 0.2)] // OCR: bottom-left origin
    let glyph = line("|", 0.45, 0.22, h: 0.16), boundary = line("|", 0.3, 0.1, h: 0.8)
    let frame = [line("|", 0, 0, h: 1), line("_", 0, 1, w: 1)]
    let r = renderAscii(text, [glyph, boundary] + frame, nil, nil, 40, 10)
    let rs = rows(r.linesText.replacingOccurrences(of: underline, with: "")).map(cols)
    XCTAssertTrue(rs.allSatisfy { $0[18] != "|" })
    XCTAssertEqual(rs.filter { $0[12] == "|" }.count, 9)
    XCTAssertTrue(rs.allSatisfy { $0[0] == "|" })
    XCTAssertTrue(rs.last!.allSatisfy { $0 == "_" || $0 == "|" })
  }

  func testCursorTakesPrecedenceAtABoundaryIntersection() {
    let r = renderAscii([], [line("|", 0.4, 0, h: 1), line("_", 0, 0.4, w: 1)], 0.4, 0.4, 20, 10)
    let row = cols(rows(r.finalText)[4])
    XCTAssertEqual(row[8], pointer)
    XCTAssertEqual(row.count, 19) // the emoji fills two of the 20 columns
    XCTAssertEqual(r.finalText.components(separatedBy: pointer).count - 1, 1)
  }

  func testCursorEmojiDoesNotShiftLaterColumns() {
    let r = renderAscii([], [line("|", 0.5, 0, h: 1)], 0.25, 0.5, 20, 10)
    let row = cols(rows(r.finalText)[5])
    XCTAssertEqual(row.firstIndex(of: pointer), 5)
    XCTAssertEqual(row.firstIndex(of: "|").map { $0 + 1 }, 10) // +1: the emoji is two columns wide
  }

  func testOverflowingTextDoesNotExtendTheCanvas() {
    let r = renderAscii([Obs(text: "long overflowing text", x: 0.8, y: 0.8, w: 0.2, h: 0.1)], [], nil, nil, 10, 5)
    XCTAssertTrue(rows(r.finalText).allSatisfy { cols($0).count == 10 })
  }

  func testTextRunningIntoAVerticalLineKeepsItsEndAroundAnEllipsis() {
    let text = Obs(text: "here-is-a-very-long-text-doesnt-fit-inside", x: 0, y: 0.5, w: 0.9, h: 0.1)
    let r = renderAscii([text], [line("|", 25.0 / 40, 0, h: 1)], nil, nil, 40, 3)
    XCTAssertTrue(rows(r.finalText)[1].hasPrefix("here-is-a-very-long\u{2026}nside|"), rows(r.finalText)[1])
  }

  func testFitKeepsStartAndLastCharacters() {
    XCTAssertEqual(String(fit(Array("abcdefghij"), 7)), "abc\u{2026}hij")
    XCTAssertEqual(String(fit(Array("short"), 7)), "short")
    XCTAssertEqual(String(fit(Array("abcdef"), 2)), "ab")
  }

  func testWideCharactersTakeTwoColumnsSoLinesStayAligned() {
    let r = renderAscii([Obs(text: "\u{6771}\u{4EAC}\u{99C5}", x: 0, y: 0.5, w: 0.2, h: 0.1)],
                        [line("|", 10.0 / 20, 0, h: 1)], nil, nil, 20, 3)
    let rs = rows(r.finalText)
    XCTAssertEqual(rs[1], "\u{6771}\u{4EAC}\u{99C5}    |         ")
    XCTAssertEqual(rs[0], "          |         ")
  }
}
