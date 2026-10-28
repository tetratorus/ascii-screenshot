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
  var history: String?
  var keepDays = 14
}

/// Keeps OCR/line state between frames and only redoes work for the parts of the screen that changed.
final class Pipeline {
  let opts: Options
  let ocr: TextRecognizer
  private let recognize: (CVPixelBuffer, [CGRect]) -> [[Obs]]
  private var prev: CVPixelBuffer?
  private(set) var obs: [Obs] = []
  private(set) var lines: [DLine] = []
  private var sinceFull = 0
  private(set) var imageSize = (0, 0)
  private var reference: [UInt8] = []
  static let tile = 32

  init(_ opts: Options, recognize: ((CVPixelBuffer, [CGRect]) -> [[Obs]])? = nil) {
    self.opts = opts
    ocr = TextRecognizer(fast: opts.fast, languageCorrection: opts.languageCorrection, stats: opts.stats)
    self.recognize = recognize ?? ocr.recognize
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
    guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return false }
    let bm = Bitmap(base: base.assumingMemoryBound(to: UInt8.self),
                    width: w, height: h, rowBytes: CVPixelBufferGetBytesPerRow(pb))

    var regions: [CGRect]? = nil // pixel rects, top-left origin; nil = everything
    var scrolled: Int?
    if let prev, CVPixelBufferGetWidth(prev) == w, CVPixelBufferGetHeight(prev) == h {
      CVPixelBufferLockBaseAddress(prev, .readOnly)
      let old = Bitmap(base: CVPixelBufferGetBaseAddress(prev)!.assumingMemoryBound(to: UInt8.self),
                       width: w, height: h, rowBytes: CVPixelBufferGetBytesPerRow(prev))
      var dirty: [CGRect]
      if let dy = scrollShift(old, bm) {
        dirty = followScroll(dy, old, bm)
        scrolled = dy
      } else {
        dirty = dirtyRegions(old, bm)
      }
      CVPixelBufferUnlockBaseAddress(prev, .readOnly)
      if dirty.isEmpty {
        if opts.stats { log(String(format: "frame %dx%d unchanged; OCR skipped cpu=%.2fms", w, h, (cpuTime() - t0) * 1000)) }
        return false
      }
      if sinceFull < opts.fullEvery { regions = dirty }
    }
    prev = pb
    imageSize = (w, h)
    let tDiff = Date()

    lines = detectLines(bm)
    let tLines = Date()

    let W = Double(w), H = Double(h)
    if let rects = regions {
      let grown = expandOverText(rects, W, H)
      regions = grown.flatMap { $0.reduce(0, { $0 + $1.width * $1.height }) > 0.5 * W * H ? nil : $0 }
    }
    if let rects = regions {
      let rois = rects.map { CGRect(x: $0.minX / W, y: 1 - $0.maxY / H, width: $0.width / W, height: $0.height / H) }
      let fresh = opts.atlas && rects.count > 1 ? ocr.recognizeAtlas(pb, rects, using: recognize) : Array(recognize(pb, rois).joined())
      obs.removeAll { o in rois.contains { $0.intersects(CGRect(x: o.x, y: o.y, width: o.w, height: o.h)) } }
      obs += fresh
      sinceFull += 1
    } else {
      obs = recognize(pb, [CGRect(x: 0, y: 0, width: 1, height: 1)])[0]
      sinceFull = 0
    }
    if opts.stats {
      let ms = { (a: Date, b: Date) in String(format: "%.0f", b.timeIntervalSince(a) * 1000) }
      let area = (regions?.reduce(0.0) { $0 + Double($1.width * $1.height) }).map { $0 / (W * H) * 100 } ?? 100
      log(String(format: "frame %dx%d ocr=%.1f%% of screen (%d regions) scroll=%d diff=%@ms lines=%@ms ocr=%@ms cpu=%.0fms [%@]",
                 w, h, area, regions?.count ?? 1, scrolled ?? 0, ms(w0, tDiff), ms(tDiff, tLines), ms(tLines, Date()),
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

  /// Vertical scroll between frames: the shift dy such that new row y shows old row y+dy, found by matching
  /// row slices of what changed. Nil when the change doesn't look like a scroll.
  func scrollShift(_ a: Bitmap, _ b: Bitmap) -> Int? {
    let S = 128, w = a.width, h = a.height
    var y0 = h, y1 = 0
    for y in 0..<h where memcmp(a.base + y * a.rowBytes, b.base + y * b.rowBytes, w * 4) != 0 { y0 = min(y0, y); y1 = y + 1 }
    guard y1 - y0 >= 16 else { return nil }
    var votes: [Int: Int] = [:], changed = 0
    for x0 in stride(from: 0, to: w, by: S) {
      let n = min(S, w - x0)
      guard n > 1 else { continue }
      // Plain-colour slices match anywhere, so they don't vote.
      func key(_ p: UnsafePointer<UInt8>) -> Int? {
        if memcmp(p, p + 4, (n - 1) * 4) == 0 { return nil }
        var hs = Hasher()
        hs.combine(bytes: UnsafeRawBufferPointer(start: p, count: n * 4))
        return hs.finalize()
      }
      var rowOf: [Int: Int] = [:] // slice hash -> old row, -1 if it repeats
      for y in y0..<y1 { if let k = key(a.base + y * a.rowBytes + x0 * 4) { rowOf[k] = rowOf[k] == nil ? y : -1 } }
      for y in y0..<y1 {
        let pa = a.base + y * a.rowBytes + x0 * 4, pb = b.base + y * b.rowBytes + x0 * 4
        guard memcmp(pa, pb, n * 4) != 0, let k = key(pb) else { continue }
        changed += 1
        if let oy = rowOf[k], oy >= 0 { votes[oy - y, default: 0] += 1 }
      }
    }
    guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 16, best.value * 4 >= changed else { return nil }
    return best.key
  }

  /// After a scroll by dy, move cached text along with the page and return only the regions that really need
  /// reading: newly revealed rows and anything that changed on top of the scroll.
  private func followScroll(_ dy: Int, _ a: Bitmap, _ b: Bitmap) -> [CGRect] {
    let w = a.width, h = a.height, rb = w * 4, T = Pipeline.tile
    if reference.count != rb * h { reference = [UInt8](repeating: 0, count: rb * h) }
    // The old frame, with every tile row that matches its scrolled source swapped for that source.
    var dirty = reference.withUnsafeMutableBytes { buf -> [CGRect] in
      let d = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<h {
        let pa = a.base + y * a.rowBytes, pb = b.base + y * b.rowBytes, row = d + y * rb, sy = y + dy
        memcpy(row, pa, rb)
        guard sy >= 0, sy < h, memcmp(pa, pb, rb) != 0 else { continue }
        let src = a.base + sy * a.rowBytes
        for x0 in stride(from: 0, to: w, by: T) {
          let n = min(T, w - x0) * 4
          if memcmp(src + x0 * 4, pb + x0 * 4, n) == 0 { memcpy(row + x0 * 4, src + x0 * 4, n) }
        }
      }
      return dirtyRegions(Bitmap(base: UnsafePointer(d), width: w, height: h, rowBytes: rb), b)
    }
    let bounds = CGRect(x: 0, y: 0, width: w, height: h), W = Double(w), H = Double(h)
    func same(_ r: CGRect, _ shift: Int) -> Bool {
      let r = r.integral.intersection(bounds)
      guard !r.isNull, !r.isEmpty else { return false }
      let x0 = Int(r.minX), n = Int(r.width) * 4
      for y in Int(r.minY)..<Int(r.maxY) {
        let sy = y + shift
        guard sy >= 0, sy < h, memcmp(b.base + y * b.rowBytes + x0 * 4, a.base + sy * a.rowBytes + x0 * 4, n) == 0 else { return false }
      }
      return true
    }
    func changedRows(_ r: CGRect) -> CGRect? {
      let r = r.integral.intersection(bounds)
      guard !r.isNull, !r.isEmpty else { return nil }
      let x0 = Int(r.minX), n = Int(r.width) * 4
      let rows = (Int(r.minY)..<Int(r.maxY)).filter {
        memcmp(b.base + $0 * b.rowBytes + x0 * 4, a.base + $0 * a.rowBytes + x0 * 4, n) != 0
      }
      guard let lo = rows.first, let hi = rows.last else { return nil }
      return CGRect(x: r.minX, y: CGFloat(lo), width: r.width, height: CGFloat(hi - lo + 1))
    }
    let residual = dirty.reduce(0.0) { $0 + Double($1.width * $1.height) } / (W * H)
    var kept = 0, movedN = 0, dropped = 0
    defer { if opts.stats { log(String(format: "scroll dy=%d residual=%.1f%% kept=%d moved=%d dropped=%d", dy, residual * 100, kept, movedN, dropped)) } }
    obs = obs.compactMap { o in
      let box = CGRect(x: o.x * W, y: (1 - o.y - o.h) * H, width: o.w * W, height: o.h * H)
      guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return nil }
      if same(box, 0) { kept += 1; return o }
      let moved = box.offsetBy(dx: 0, dy: CGFloat(-dy))
      if bounds.contains(moved.integral), same(moved, dy) {
        var m = o
        m.y += Double(dy) / H
        movedN += 1
        return m
      }
      // Text that only partly survived the scroll (cut by the window edge, or half revealed) is read again
      // where it now sits, skipping rows that didn't change, like a toolbar it slid under.
      dropped += 1
      if let r = changedRows(moved) { dirty.append(r) }
      return nil
    }
    return dirty
  }

  /// Grow regions until no cached text box straddles a region edge, then merge overlaps.
  /// Returns nil (read the whole screen) if that doesn't settle, so a bad box can never spin the CPU.
  private func expandOverText(_ input: [CGRect], _ W: Double, _ H: Double) -> [CGRect]? {
    let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    let boxes = obs.compactMap { o -> CGRect? in
      let r = CGRect(x: o.x * W, y: (1 - o.y - o.h) * H, width: o.w * W, height: o.h * H).insetBy(dx: -2, dy: -2)
      guard [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) else { return nil }
      let c = r.intersection(bounds)
      return c.isNull || c.isEmpty ? nil : c.integral
    }
    var rects = input.filter { !$0.isNull && !$0.isEmpty }, changed = true, passes = 0
    while changed {
      changed = false
      passes += 1
      if passes > 64 { return nil }
      for i in rects.indices {
        for b in boxes where rects[i].intersects(b) && !rects[i].contains(b) { rects[i] = rects[i].union(b); changed = true }
      }
      var merged: [CGRect] = []
      for r in rects {
        if let j = merged.firstIndex(where: { $0.intersects(r) }) { merged[j] = merged[j].union(r); changed = true } else { merged.append(r) }
      }
      rects = merged
    }
    return rects.map { $0.intersection(bounds).integral }.filter { !$0.isNull && !$0.isEmpty }
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
