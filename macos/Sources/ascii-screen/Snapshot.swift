import CoreGraphics
import CoreVideo
import Foundation

/// Pixels and their position in global, top-left screen coordinates (points, not Retina pixels).
/// For image files, bounds are in image pixels instead.
struct Snapshot {
  let pixels: CVPixelBuffer
  let bounds: CGRect
  var cursor: CGPoint?

  var normalizedCursor: CGPoint? {
    guard let cursor, bounds.contains(cursor) else { return nil }
    return CGPoint(x: (cursor.x - bounds.minX) / bounds.width, y: (cursor.y - bounds.minY) / bounds.height)
  }

  func cropped(to region: CGRect) throws -> Snapshot {
    let clipped = bounds.intersection(region)
    guard !clipped.isNull, !clipped.isEmpty else {
      throw NSError(domain: "ascii-screen", code: 3, userInfo: [NSLocalizedDescriptionKey: "--region does not intersect the capture"])
    }
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    let sx = Double(width) / bounds.width, sy = Double(height) / bounds.height
    let rect = CGRect(x: (clipped.minX - bounds.minX) * sx, y: (clipped.minY - bounds.minY) * sy,
                      width: clipped.width * sx, height: clipped.height * sy).integral
      .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw NSError(domain: "ascii-screen", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "cannot allocate cropped capture"])
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(buffer, [])
      CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
    }
    guard let src = CVPixelBufferGetBaseAddress(pixels), let dst = CVPixelBufferGetBaseAddress(buffer) else {
      throw NSError(domain: "ascii-screen", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot read capture pixels"])
    }
    for row in 0..<h {
      memcpy(dst + row * CVPixelBufferGetBytesPerRow(buffer),
             src + (y + row) * CVPixelBufferGetBytesPerRow(pixels) + x * 4, w * 4)
    }
    return Snapshot(pixels: buffer,
                    bounds: CGRect(x: bounds.minX + Double(x) / sx, y: bounds.minY + Double(y) / sy,
                                   width: Double(w) / sx, height: Double(h) / sy), cursor: cursor)
  }

  func rows(_ opts: Options) -> Int {
    opts.height ?? Frame.rows(columns: opts.width, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
  }

  func geometry(_ opts: Options, units: String) -> String {
    let dx = bounds.width / Double(opts.width), dy = bounds.height / Double(rows(opts))
    var text = String(format: "region (%g,%g,%g,%g) %@; grid %dx%d; cell centers: x=%g+(col+0.5)*%g, y=%g+(row+0.5)*%g (zero-based)",
                      bounds.minX, bounds.minY, bounds.width, bounds.height, units, opts.width, rows(opts), bounds.minX, dx, bounds.minY, dy)
    if let cursor, normalizedCursor != nil { text += String(format: "; mouse (%g,%g)", cursor.x, cursor.y) }
    return text
  }

  func render(_ opts: Options, raster: Bool) -> String {
    if !raster {
      let pipeline = Pipeline(opts)
      pipeline.process(pixels)
      return pipeline.render(cursor: opts.cursor ? normalizedCursor : nil)
    }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { return "" }
    let bitmap = Bitmap(base: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(pixels),
                        height: CVPixelBufferGetHeight(pixels), rowBytes: CVPixelBufferGetBytesPerRow(pixels))
    return renderRaster(bitmap, columns: opts.width, rows: rows(opts), cursor: opts.cursor ? normalizedCursor : nil)
  }
}

/// A direct luminance view for icons and graphics that OCR doesn't read. Average source pixels per cell;
/// invert a predominantly light image so its background stays blank. No inferred shapes or labels.
func renderRaster(_ bitmap: Bitmap, columns: Int, rows: Int, cursor: CGPoint? = nil) -> String {
  let ramp = Array(" .:-=+*#%@")
  var values = [Double](repeating: 0, count: columns * rows)
  for row in 0..<rows {
    let y0 = row * bitmap.height / rows, y1 = min(bitmap.height, max(y0 + 1, (row + 1) * bitmap.height / rows))
    for col in 0..<columns {
      let x0 = col * bitmap.width / columns, x1 = min(bitmap.width, max(x0 + 1, (col + 1) * bitmap.width / columns))
      var sum = 0.0
      for y in y0..<y1 { for x in x0..<x1 {
        sum += Double(bitmap.px(x, y, 0)) * 0.0722 + Double(bitmap.px(x, y, 1)) * 0.7152 + Double(bitmap.px(x, y, 2)) * 0.2126
      } }
      values[row * columns + col] = sum / Double((x1 - x0) * (y1 - y0))
    }
  }
  let low = values.min() ?? 0, high = values.max() ?? 0, span = high - low
  let invert = values.reduce(0, +) / Double(values.count) > (low + high) / 2
  var grid = values.map { value -> Character in
    guard span > 1 else { return " " }
    let level = (value - low) / span
    return ramp[min(ramp.count - 1, max(0, Int(((invert ? 1 - level : level) * Double(ramp.count - 1)).rounded())))]
  }
  if let cursor, cursor.x >= 0, cursor.x < 1, cursor.y >= 0, cursor.y < 1 {
    grid[min(rows - 1, Int(cursor.y * Double(rows))) * columns + min(columns - 1, Int(cursor.x * Double(columns)))] = "@"
  }
  return (0..<rows).map { String(grid[$0 * columns..<($0 + 1) * columns]) }.joined(separator: "\n")
}
