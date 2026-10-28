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

  private func deviceName(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: return "cpu"
    case .gpu: return "gpu"
    case .neuralEngine: return "neuralEngine"
    @unknown default: return "unknown"
    }
  }
}
