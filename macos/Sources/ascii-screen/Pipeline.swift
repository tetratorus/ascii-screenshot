import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct Options {
  var width = 160
  var height: Int?
  var interval = 1.0
  var scale = 1.0
  var fast = false
  var languageCorrection = false
  var cursor = true
  var out: String?
  var stats = false
  var display = 0
  var fullEvery = 30
  var atlas = true
}

/// Keeps OCR/line state between frames and only redoes work for the parts of the screen that changed.
final class Pipeline {
  let opts: Options
  let ocr: TextRecognizer
  private var prev: CVPixelBuffer?
  private(set) var obs: [Obs] = []
  private(set) var lines: [DLine] = []
  private var sinceFull = 0
  private(set) var imageSize = (0, 0)
  static let tile = 32

  init(_ opts: Options) {
    self.opts = opts
    ocr = TextRecognizer(fast: opts.fast, languageCorrection: opts.languageCorrection)
  }

  var canvasHeight: Int {
    opts.height ?? min(100, max(1, jsFloor(Double(opts.width) * Double(imageSize.1) / Double(imageSize.0) * 0.5)))
  }

  /// Returns false when the frame is pixel-identical to the previous one.
  @discardableResult
  func process(_ pb: CVPixelBuffer) -> Bool {
    let t0 = cpuTime(), w0 = Date()
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bm = Bitmap(base: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self),
                    width: w, height: h, rowBytes: CVPixelBufferGetBytesPerRow(pb))

    var regions: [CGRect]? = nil // pixel rects, top-left origin; nil = everything
    if let prev, CVPixelBufferGetWidth(prev) == w, CVPixelBufferGetHeight(prev) == h, sinceFull < opts.fullEvery {
      CVPixelBufferLockBaseAddress(prev, .readOnly)
      let old = Bitmap(base: CVPixelBufferGetBaseAddress(prev)!.assumingMemoryBound(to: UInt8.self),
                       width: w, height: h, rowBytes: CVPixelBufferGetBytesPerRow(prev))
      let dirty = dirtyRegions(old, bm)
      CVPixelBufferUnlockBaseAddress(prev, .readOnly)
      if dirty.isEmpty { return false }
      regions = dirty
    }
    prev = pb
    imageSize = (w, h)
    let tDiff = Date()

    lines = detectLines(bm)
    let tLines = Date()

    let W = Double(w), H = Double(h)
    if var rects = regions {
      rects = expandOverText(rects, W, H)
      if rects.reduce(0, { $0 + $1.width * $1.height }) > 0.5 * W * H { regions = nil } else { regions = rects }
    }
    if let rects = regions {
      let rois = rects.map { CGRect(x: $0.minX / W, y: 1 - $0.maxY / H, width: $0.width / W, height: $0.height / H) }
      let fresh = opts.atlas && rects.count > 1 ? ocr.recognizeAtlas(pb, rects) : Array(ocr.recognize(pb, rois).joined())
      obs.removeAll { o in rois.contains { $0.intersects(CGRect(x: o.x, y: o.y, width: o.w, height: o.h)) } }
      obs += fresh
      sinceFull += 1
    } else {
      obs = ocr.recognize(pb, [CGRect(x: 0, y: 0, width: 1, height: 1)])[0]
      sinceFull = 0
    }
    if opts.stats {
      let ms = { (a: Date, b: Date) in String(format: "%.0f", b.timeIntervalSince(a) * 1000) }
      let area = (regions?.reduce(0.0) { $0 + Double($1.width * $1.height) }).map { $0 / (W * H) * 100 } ?? 100
      log(String(format: "frame %dx%d ocr=%.1f%% of screen (%d regions) diff=%@ms lines=%@ms ocr=%@ms cpu=%.0fms [%@]",
                 w, h, area, regions?.count ?? 1, ms(w0, tDiff), ms(tDiff, tLines), ms(tLines, Date()),
                 (cpuTime() - t0) * 1000, ocr.device))
    }
    return true
  }

  func render(cursor: CGPoint?) -> String {
    renderAscii(obs, lines, cursor.map { Double($0.x) }, cursor.map { Double($0.y) }, opts.width, canvasHeight).finalText
  }

  /// Bounding boxes of changed tiles, padded so text that spills out of the change is re-read whole.
  private func dirtyRegions(_ a: Bitmap, _ b: Bitmap) -> [CGRect] {
    let T = Pipeline.tile, cols = (a.width + T - 1) / T, rows = (a.height + T - 1) / T
    var dirty = [Bool](repeating: false, count: cols * rows)
    for y in 0..<a.height {
      let ra = a.base + y * a.rowBytes, rbp = b.base + y * b.rowBytes, ty = y / T
      if memcmp(ra, rbp, a.width * 4) == 0 { continue }
      for tx in 0..<cols where !dirty[ty * cols + tx] {
        let x0 = tx * T, n = min(T, a.width - x0)
        if memcmp(ra + x0 * 4, rbp + x0 * 4, n * 4) != 0 { dirty[ty * cols + tx] = true }
      }
    }
    // 8-connected components of dirty tiles.
    var seen = dirty.map { !$0 }, rects: [CGRect] = []
    for start in 0..<dirty.count where !seen[start] {
      var stack = [start], minX = cols, minY = rows, maxX = 0, maxY = 0
      seen[start] = true
      while let i = stack.popLast() {
        let x = i % cols, y = i / cols
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        for dy in -1...1 { for dx in -1...1 {
          let nx = x + dx, ny = y + dy
          if nx >= 0, ny >= 0, nx < cols, ny < rows, !seen[ny * cols + nx] { seen[ny * cols + nx] = true; stack.append(ny * cols + nx) }
        } }
      }
      rects.append(CGRect(x: minX * T - 2 * T, y: minY * T - T / 2, width: (maxX - minX + 5) * T, height: (maxY - minY + 2) * T))
    }
    let bounds = CGRect(x: 0, y: 0, width: a.width, height: a.height)
    return rects.map { $0.intersection(bounds) }
  }

  /// Grow regions until no cached text box straddles a region edge, then merge overlaps.
  private func expandOverText(_ input: [CGRect], _ W: Double, _ H: Double) -> [CGRect] {
    let boxes = obs.map { CGRect(x: $0.x * W, y: (1 - $0.y - $0.h) * H, width: $0.w * W, height: $0.h * H).insetBy(dx: -2, dy: -2) }
    var rects = input, changed = true
    while changed {
      changed = false
      for i in rects.indices {
        for b in boxes where rects[i].intersects(b) && !rects[i].contains(b) { rects[i] = rects[i].union(b); changed = true }
      }
      var merged: [CGRect] = []
      for r in rects {
        if let j = merged.firstIndex(where: { $0.intersects(r) }) { merged[j] = merged[j].union(r); changed = true } else { merged.append(r) }
      }
      rects = merged
    }
    let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    return rects.map { $0.intersection(bounds).integral }
  }
}

func cpuTime() -> Double {
  var u = rusage()
  getrusage(RUSAGE_SELF, &u)
  return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Decode an image file into a BGRA pixel buffer without colour conversion.
func loadImage(_ path: String) -> CVPixelBuffer? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
  var pb: CVPixelBuffer?
  CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA,
                      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
  guard let pb else { return nil }
  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }
  let space = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
  guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return nil }
  ctx.interpolationQuality = .none
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
  return pb
}
