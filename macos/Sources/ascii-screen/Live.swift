import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams the display through ScreenCaptureKit. The window server only delivers a frame when
/// something on screen changed, so an idle screen costs (almost) nothing.
final class Live: NSObject, SCStreamOutput, SCStreamDelegate {
  private let opts: Options
  private let pipeline: Pipeline
  private let queue = DispatchQueue(label: "ascii-screen", qos: .utility)
  private var stream: SCStream?
  private var displayBounds = CGRect.zero
  private let output: FrameOutput
  private var lastCursorCell: (Int, Int)?
  private var timer: DispatchSourceTimer?
  private var running = false
  private var deliveredFrames = 0

  init(_ opts: Options) {
    self.opts = opts
    pipeline = Pipeline(opts)
    let tty = isatty(STDOUT_FILENO) != 0
    output = FrameOutput { text in
      if let out = opts.out {
        try text.write(toFile: out, atomically: true, encoding: .utf8)
      } else {
        try FileHandle.standardOutput.write(contentsOf: Data(((tty ? "\u{1B}[H\u{1B}[2J" : "") + text + (tty ? "" : "\n\u{0C}\n")).utf8))
      }
    }
  }

  func start() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard opts.display < content.displays.count else { throw NSError(domain: "ascii-screen", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display \(opts.display)"]) }
    let display = content.displays[opts.display]
    displayBounds = CGDisplayBounds(display.displayID)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(Double(display.width) * opts.scale)
    cfg.height = Int(Double(display.height) * opts.scale)
    cfg.minimumFrameInterval = CMTime(seconds: opts.interval, preferredTimescale: 600)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    cfg.queueDepth = 3
    let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    stream = s
    try await resume()
    if opts.cursor { startCursorTimer() }
    observePower()
  }

  private func resume() async throws {
    guard !running, let stream else { return }
    try await stream.startCapture()
    running = true
  }

  private func pause() async {
    guard running, let stream else { return }
    try? await stream.stopCapture()
    running = false
  }

  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    if opts.stats {
      deliveredFrames += 1
      let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
      let raw = info?[.status] as? Int
      let complete = raw.flatMap(SCFrameStatus.init(rawValue:)) == .complete
      log("capture delivery=\(deliveredFrames) status=\(raw.map(String.init) ?? "missing") complete=\(complete)")
    }
    guard type == .screen, sb.isValid,
          let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
          let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
          let pb = sb.imageBuffer else { return }
    if pipeline.process(pb) { emit() }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    log("capture stopped: \(error.localizedDescription)")
    exit(1)
  }

  /// The cursor isn't in the captured frames (so moving it wakes nothing); poll it cheaply instead.
  private func startCursorTimer() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + opts.interval, repeating: opts.interval, leeway: .milliseconds(Int(opts.interval * 500)))
    t.setEventHandler { [weak self] in
      guard let self, self.running, self.pipeline.imageSize.0 > 0 else { return }
      let cell = self.cursor().map { (jsRound(Double($0.x) * Double(self.opts.width)), jsRound(Double($0.y) * Double(self.pipeline.canvasHeight))) }
      if cell?.0 != self.lastCursorCell?.0 || cell?.1 != self.lastCursorCell?.1 { self.emit() }
    }
    t.resume()
    timer = t
  }

  private func cursor() -> CGPoint? {
    guard opts.cursor, let loc = CGEvent(source: nil)?.location, displayBounds.contains(loc) else { return nil }
    return CGPoint(x: (loc.x - displayBounds.minX) / displayBounds.width, y: (loc.y - displayBounds.minY) / displayBounds.height)
  }

  private func emit() {
    let c = cursor()
    lastCursorCell = c.map { (jsRound(Double($0.x) * Double(opts.width)), jsRound(Double($0.y) * Double(pipeline.canvasHeight))) }
    do {
      try output.emit(pipeline.render(cursor: c))
    } catch {
      log("cannot write ASCII output: \(error.localizedDescription)")
      exit(1)
    }
  }

  /// Stop capturing entirely while the screen is locked or asleep.
  private func observePower() {
    let pauseFn: (Notification) -> Void = { [weak self] _ in Task { await self?.pause() } }
    let resumeFn: (Notification) -> Void = { [weak self] _ in Task { try? await self?.resume() } }
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil, using: pauseFn)
    dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil, using: resumeFn)
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil, using: pauseFn)
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil, using: resumeFn)
  }
}

func captureOnce(_ opts: Options) async throws -> CVPixelBuffer {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  let display = content.displays[opts.display]
  let cfg = SCStreamConfiguration()
  cfg.width = Int(Double(display.width) * opts.scale)
  cfg.height = Int(Double(display.height) * opts.scale)
  cfg.pixelFormat = kCVPixelFormatType_32BGRA
  cfg.showsCursor = false
  let sb = try await SCScreenshotManager.captureSampleBuffer(
    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
  guard let pb = sb.imageBuffer else { throw NSError(domain: "ascii-screen", code: 2) }
  return pb
}
