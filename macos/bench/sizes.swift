import Foundation
import Vision
import CoreGraphics
import ImageIO
func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec)/1e6 }
let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(s, 0, nil)!
let fast = CommandLine.arguments.contains("--fast")
func ocr(_ i: CGImage) -> Int { let r = VNRecognizeTextRequest(); r.recognitionLevel = fast ? .fast : .accurate; r.usesLanguageCorrection = false
  try! VNImageRequestHandler(cgImage: i).perform([r]); return r.results?.count ?? 0 }
_ = ocr(img)
for f in [0.005, 0.01, 0.03, 0.1, 0.25, 0.5, 1.0] {
  let w = Int(Double(img.width) * f.squareRoot()), h = Int(Double(img.height) * f.squareRoot())
  let c = img.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))!
  let c0 = cpu(), t0 = Date(); var n = 0; for _ in 0..<3 { n = ocr(c) }
  print(String(format: "area %5.1f%% (%4dx%4d) wall %4.0fms cpu %4.0fms obs %d", f*100, w, h, -t0.timeIntervalSinceNow/3*1000, (cpu()-c0)/3*1000, n))
}
