import Foundation
import Vision
import CoreGraphics
import ImageIO

func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec)/1e6 }
func now() -> Double { Date().timeIntervalSince1970 }
func load(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }

let fast = CommandLine.arguments.contains("--fast")
func req(_ roi: CGRect = CGRect(x:0,y:0,width:1,height:1)) -> VNRecognizeTextRequest {
  let r = VNRecognizeTextRequest(); r.recognitionLevel = fast ? .fast : .accurate
  r.usesLanguageCorrection = false; r.recognitionLanguages = ["en-US"]; r.regionOfInterest = roi; return r }
struct O { var s: String; var r: CGRect } // pixel rect, top-left origin
func run(_ img: CGImage, _ rois: [CGRect]) -> [[O]] {  // rois in pixels top-left
  let W = Double(img.width), H = Double(img.height)
  let reqs = rois.map { p in req(CGRect(x: p.minX/W, y: 1 - p.maxY/H, width: p.width/W, height: p.height/H)) }
  try! VNImageRequestHandler(cgImage: img).perform(reqs)
  return reqs.map { ($0.results ?? []).compactMap { o in
    guard let s = o.topCandidates(1).first?.string else { return nil }
    let b = VNImageRectForNormalizedRect(o.boundingBox, img.width, img.height)
    return O(s: s, r: CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)) } }
}
func crop(_ img: CGImage, _ r: CGRect) -> CGImage { img.cropping(to: r)! }
// shelf-pack crops into one image with gaps filled from background color white
func atlas(_ crops: [CGImage], gap: Int = 12) -> (CGImage, [CGRect]) {
  let area = crops.reduce(0) { $0 + ($1.width+gap)*($1.height+gap) }
  let maxW = crops.map(\.width).max()!
  let AW = max(maxW + gap, Int(Double(area).squareRoot() * 1.3))
  var x = gap, y = gap, rowH = 0; var places: [CGRect] = []
  for c in crops { if x + c.width + gap > AW { x = gap; y += rowH + gap; rowH = 0 }
    places.append(CGRect(x: x, y: y, width: c.width, height: c.height)); x += c.width + gap; rowH = max(rowH, c.height) }
  let AH = y + rowH + gap
  let ctx = CGContext(data: nil, width: AW, height: AH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: AW, height: AH))
  for (c, p) in zip(crops, places) { ctx.draw(c, in: CGRect(x: p.minX, y: Double(AH) - p.maxY, width: p.width, height: p.height)) }
  return (ctx.makeImage()!, places)
}
func lev(_ a: String, _ b: String) -> Int { let a = Array(a), b = Array(b); if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
  var d = Array(0...b.count); for i in 1...a.count { var p = d[0]; d[0] = i; for j in 1...b.count { let t = d[j]; d[j] = min(d[j]+1, d[j-1]+1, p + (a[i-1]==b[j-1] ? 0:1)); p = t } }; return d[b.count] }
func text(_ os: [O]) -> String { os.sorted { abs($0.r.midY-$1.r.midY) > 4 ? $0.r.midY < $1.r.midY : $0.r.minX < $1.r.minX }.map(\.s).joined(separator: " ") }
func sim(_ a: String, _ b: String) -> Double { let m = max(a.count, b.count); return m == 0 ? 1 : 1 - Double(lev(a,b))/Double(m) }

func measure(_ reps: Int, _ f: () -> Void) -> (Double, Double) { let c0 = cpu(), t0 = now(); for _ in 0..<reps { f() }
  return ((now()-t0)/Double(reps)*1000, (cpu()-c0)/Double(reps)*1000) }

let path = CommandLine.arguments[1]
let img = load(path); let W = img.width, H = img.height
let full = run(img, [CGRect(x: 0, y: 0, width: W, height: H)])[0]
_ = measure(1) { _ = run(img, [CGRect(x: 0, y: 0, width: W, height: H)]) }
let (fw, fc) = measure(2) { _ = run(img, [CGRect(x: 0, y: 0, width: W, height: H)]) }
print("\(path.split(separator: "/").last!) \(W)x\(H) full: wall=\(Int(fw))ms cpu=\(Int(fc))ms obs=\(full.count)")
// regions = padded text boxes, chosen spread out deterministically
var rng = SystemRandomNumberGenerator()
var g = full.filter { $0.r.width > 30 }.map { o -> CGRect in o.r.insetBy(dx: -10, dy: -6).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H)) }
// drop overlapping
var picks: [CGRect] = []; for r in g.shuffled(using: &rng) where !picks.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) { picks.append(r) }
for K in [1, 3, 5, 10, 20] where K <= picks.count {
  let rs = Array(picks.prefix(K))
  let truth = rs.map { r in text(full.filter { r.contains(CGPoint(x: $0.r.midX, y: $0.r.midY)) }) }
  let px = rs.reduce(0.0) { $0 + $1.width*$1.height } / Double(W*H) * 100
  var outA: [[O]] = [], outB: [[O]] = [], outC: [[O]] = [], outD: [[O]] = []
  let a = measure(3) { outA = rs.map { run(img, [$0])[0] } }                 // separate handlers on full image + ROI
  let b = measure(3) { outB = run(img, rs) }                                   // one handler, K ROI requests (current code)
  let cs = rs.map { crop(img, $0) }
  let c = measure(3) { outC = cs.map { cimg in run(cimg, [CGRect(x: 0, y: 0, width: cimg.width, height: cimg.height)])[0] } } // separate cropped images
  var at: (CGImage, [CGRect])!
  let d = measure(3) { at = atlas(cs); let os = run(at.0, [CGRect(x: 0, y: 0, width: at.0.width, height: at.0.height)])[0]
    outD = at.1.map { p in os.filter { p.insetBy(dx: -3, dy: -3).contains(CGPoint(x: $0.r.midX, y: $0.r.midY)) } } }
  if CommandLine.arguments.contains("--dump") && K == 5 { for (i, t) in truth.enumerated() { print("    truth[\(t)] multi[\(text(outB[i]))] atlas[\(text(outD[i]))]") } }
  func acc(_ out: [[O]]) -> Double { zip(truth, out).map { sim($0, text($1)) }.reduce(0,+) / Double(rs.count) * 100 }
  print(String(format: "  K=%2d area=%4.1f%% | sepROI %4.0f/%4.0fms acc %5.1f | multiROI %4.0f/%4.0fms acc %5.1f | sepCrop %4.0f/%4.0fms acc %5.1f | atlas(%dx%d) %4.0f/%4.0fms acc %5.1f",
    K, px, a.0, a.1, acc(outA), b.0, b.1, acc(outB), c.0, c.1, acc(outC), at.0.width, at.0.height, d.0, d.1, acc(outD)))
}
