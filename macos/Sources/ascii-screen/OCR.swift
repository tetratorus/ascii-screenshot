import CoreML
import CoreVideo
import Foundation
import Vision

final class TextRecognizer {
  let level: VNRequestTextRecognitionLevel
  let languageCorrection: Bool
  private(set) var device = "default"

  init(fast: Bool, languageCorrection: Bool) {
    level = fast ? .fast : .accurate
    self.languageCorrection = languageCorrection
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
      }
    }
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
}
