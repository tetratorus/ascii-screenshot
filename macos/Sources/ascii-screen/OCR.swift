import CoreML
import CoreVideo
import Foundation
import Vision

final class TextRecognizer {
  let level: VNRequestTextRecognitionLevel
  let languageCorrection: Bool
  private let stats: Bool
  private var loggedDevices = false
  private(set) var device = "default"

  init(fast: Bool, languageCorrection: Bool, stats: Bool = false) {
    level = fast ? .fast : .accurate
    self.languageCorrection = languageCorrection
    self.stats = stats
  }

  private func request(_ roi: CGRect) -> VNRecognizeTextRequest {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = level
    r.usesLanguageCorrection = languageCorrection
    r.recognitionLanguages = ["en-US"]
    r.regionOfInterest = roi
    // The Neural Engine is the most power-efficient place to run the model.
    if let devices = try? r.supportedComputeStageDevices {
      for (stage, list) in devices {
        if let ane = list.first(where: { if case .neuralEngine = $0 { return true } else { return false } }) {
          r.setComputeDevice(ane, for: stage)
          device = "neuralEngine"
        }
        if stats && !loggedDevices {
          let supported = list.map(deviceName).joined(separator: ",")
          let selected = r.computeDevice(for: stage).map(deviceName) ?? "automatic"
          log("OCR stage=\(stage.rawValue) supported=[\(supported)] selected=\(selected) (selection, not measured utilization)")
        }
      }
    } else if stats && !loggedDevices {
      log("OCR compute devices unavailable; using automatic selection")
    }
    loggedDevices = true
    return r
  }

  /// OCR each region (normalized, bottom-left origin); boxes come back in full-image coordinates.
  func recognize(_ pb: CVPixelBuffer, _ rois: [CGRect]) -> [[Obs]] {
    let reqs = rois.map(request)
    do {
      try VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform(reqs)
    } catch {
      FileHandle.standardError.write("OCR failed: \(error)\n".data(using: .utf8)!)
      return rois.map { _ in [] }
    }
    return zip(reqs, rois).map { req, roi in
      (req.results ?? []).compactMap { o in
        guard let s = o.topCandidates(1).first?.string else { return nil }
        let b = o.boundingBox
        return Obs(text: s, x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
                   w: b.width * roi.width, h: b.height * roi.height)
      }
    }
  }

  /// OCR several pixel regions (top-left origin) in a single Vision call by packing them into one image.
  /// Vision has a large fixed cost per call, so this is much cheaper than one request per region.
  func recognizeAtlas(_ pb: CVPixelBuffer, _ rects: [CGRect],
                      using recognize: ((CVPixelBuffer, [CGRect]) -> [[Obs]])? = nil) -> [Obs] {
    let gap = 12
    let src = rects.map { r in (x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height)) }.filter { $0.w > 0 && $0.h > 0 }
    guard !src.isEmpty else { return [] }
    let area = src.reduce(0) { $0 + ($1.w + gap) * ($1.h + gap) }
    let AW = max(src.map(\.w).max()! + 2 * gap, Int(Double(area).squareRoot() * 1.3))
    var x = gap, y = gap, rowH = 0
    // Shelf packing, tallest first.
    let order = src.indices.sorted { src[$0].h > src[$1].h }
    var places = [(x: Int, y: Int)](repeating: (0, 0), count: src.count)
    for i in order {
      if x + src[i].w + gap > AW { x = gap; y += rowH + gap; rowH = 0 }
      places[i] = (x, y); x += src[i].w + gap; rowH = max(rowH, src[i].h)
    }
    let AH = y + rowH + gap
    var atlas: CVPixelBuffer?
    CVPixelBufferCreate(nil, AW, AH, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &atlas)
    guard let atlas else { return [] }
    CVPixelBufferLockBaseAddress(atlas, [])
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(pb, .readOnly)
      CVPixelBufferUnlockBaseAddress(atlas, [])
    }
    guard let dst = CVPixelBufferGetBaseAddress(atlas), let sp = CVPixelBufferGetBaseAddress(pb) else { return [] }
    let dRow = CVPixelBufferGetBytesPerRow(atlas), sRow = CVPixelBufferGetBytesPerRow(pb)
    memset(dst, 0xFF, dRow * AH)
    for (r, p) in zip(src, places) {
      for row in 0..<r.h { memcpy(dst + (p.y + row) * dRow + p.x * 4, sp + (r.y + row) * sRow + r.x * 4, r.w * 4) }
    }
    let W = Double(CVPixelBufferGetWidth(pb)), H = Double(CVPixelBufferGetHeight(pb))
    let found = (recognize ?? self.recognize)(atlas, [CGRect(x: 0, y: 0, width: 1, height: 1)])[0]
    return found.compactMap { o in
      let ax = o.x * Double(AW), ay = (1 - o.y - o.h) * Double(AH), aw = o.w * Double(AW), ah = o.h * Double(AH)
      let cx = ax + aw / 2, cy = ay + ah / 2
      guard let i = places.indices.first(where: { cx >= Double(places[$0].x) && cx < Double(places[$0].x + src[$0].w)
                                                  && cy >= Double(places[$0].y) && cy < Double(places[$0].y + src[$0].h) }) else { return nil }
      let ox = Double(src[i].x) + ax - Double(places[i].x), oy = Double(src[i].y) + ay - Double(places[i].y)
      return Obs(text: o.text, x: ox / W, y: 1 - (oy + ah) / H, w: aw / W, h: ah / H)
    }
  }

  private func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "neuralEngine"
    @unknown default: return "unknown"
    }
  }
}
