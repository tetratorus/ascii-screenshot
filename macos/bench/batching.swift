import Foundation
import Vision
import CoreGraphics
import CoreText
import ImageIO
func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec)/1e6 }
func m(_ n: Int, _ f: () -> Void) -> String { let c0 = cpu(), t0 = Date(); for _ in 0..<n { f() }
  return String(format: "wall %4.0fms cpu %4.0fms", -t0.timeIntervalSinceNow/Double(n)*1000, (cpu()-c0)/Double(n)*1000) }
func mk() -> VNRecognizeTextRequest { let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.usesLanguageCorrection = false; r.recognitionLanguages = ["en-US"]; return r }
func ocr(_ i: CGImage, _ r: VNRecognizeTextRequest = mk()) -> [String] { try! VNImageRequestHandler(cgImage: i).perform([r]); return (r.results ?? []).compactMap { $0.topCandidates(1).first?.string } }
func canvas(_ w: Int, _ h: Int, _ lines: [(String, CGFloat, CGFloat)], size: CGFloat = 14) -> CGImage {
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
  for (s, x, y) in lines { let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - y - size); CTLineDraw(CTLineCreateWithAttributedString(a), ctx) }
  return ctx.makeImage()! }
let words = ["Deploy finished", "Build 4821 passed", "New message from Ana", "CPU 12% MEM 4.1GB", "Tuesday 23:41:07", "Pull request merged", "3 unread", "Downloading 435KB"]
_ = ocr(canvas(400, 100, [("warmup text", 10, 10)]))
print("== fixed cost: blank vs text, by image size")
for (w, h) in [(200, 60), (1600, 1000)] {
  print("blank \(w)x\(h):", m(3) { _ = ocr(canvas(w, h, [])) })
  print("1 line \(w)x\(h):", m(3) { _ = ocr(canvas(w, h, [("Deploy finished at 23:41", 20, 20)])) })
}
print("== cost vs number of text lines (800x800)")
for n in [1, 5, 10, 20, 40] { let ls = (0..<n).map { (words[$0 % words.count] + " \($0)", CGFloat(20 + ($0 % 2) * 400), CGFloat(20 + ($0 / 2) * 36)) }
  print("lines \(n):", m(2) { _ = ocr(canvas(800, 800, ls)) }) }
print("== request reuse / sequence handler (5 small images)")
let smalls = (0..<5).map { canvas(220, 40, [(words[$0], 8, 10)]) }
print("new request each:", m(2) { for s in smalls { _ = ocr(s) } })
let shared = mk(); print("reused request:", m(2) { for s in smalls { _ = ocr(s, shared) } })
let seq = VNSequenceRequestHandler(); print("sequence handler:", m(2) { for s in smalls { try! seq.perform([shared], on: s) } })
print("== temporal: one region (clock) changes every second for 10s")
let frames = (0..<10).map { i in canvas(220, 40, [("Tuesday 23:41:\(String(format: "%02d", i))", 8, 10)]) }
var got: [String] = []
print("A every 1s (10 calls):", m(1) { got = frames.flatMap { ocr($0) } }, got.suffix(1))
print("B 10s latest only (1 call):", m(1) { got = ocr(frames[9]) }, got)
let stack = canvas(240, 10 * 52, (0..<10).map { ("Tuesday 23:41:\(String(format: "%02d", $0))", 8, CGFloat(10 + $0 * 52)) })
print("C 10s stitched all 10 crops (1 call):", m(1) { got = ocr(stack) }, got.count, "lines")
print("== spatial: 3 separate regions change in one frame")
let three = [canvas(220, 40, [(words[1], 8, 10)]), canvas(260, 40, [(words[2], 8, 10)]), canvas(220, 40, [(words[3], 8, 10)])]
print("3 calls:", m(2) { got = three.flatMap { ocr($0) } }, got)
let packed = canvas(300, 160, [(words[1], 8, 10), (words[2], 8, 62), (words[3], 8, 114)])
print("1 stitched call:", m(2) { got = ocr(packed) }, got)
