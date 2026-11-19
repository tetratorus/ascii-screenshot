import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams the display through ScreenCaptureKit. The window server only delivers a frame when
/// something on screen changed, so an idle screen costs (almost) nothing.
final class Live: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let opts: Options
  private let pipeline: Pipeline
  private let queue = DispatchQueue(label: "ascii-screen", qos: .utility)
  private let stateLock = NSLock()
  private var stream: SCStream?
  private var displayBounds = CGRect.zero
  private var lastCursorCell: (Int, Int)?
  private var timer: DispatchSourceTimer?
  private var retryWork: DispatchWorkItem?
  private var running = false
  private var starting = false
  private var locked = false
  private var asleep = false
  private var pausedNote = ""
  private var deliveredFrames = 0
  private let sink: Sink

  private func setActiveBounds(_ bounds: CGRect?) {
    stateLock.lock()
    running = bounds != nil
    if let bounds { displayBounds = bounds }
    stateLock.unlock()
  }

  private func activeBounds() -> CGRect? {
    stateLock.lock(); defer { stateLock.unlock() }
    return running ? displayBounds : nil
  }

  init(_ opts: Options) {
    self.opts = opts
    pipeline = Pipeline(opts)
    let history = opts.history.map { History(dir: URL(fileURLWithPath: $0), keepDays: opts.keepDays) }
    sink = Sink(opts: opts, pipeline: pipeline, output: frameOutput(opts), history: history)
  }

  /// True when an empty display list means the Mac's displays are asleep or
  /// offline, rather than an invalid `--display` index.
  static func shouldWaitForDisplay(requested: Int, available: Int) -> Bool {
    available == 0 && requested == 0
  }

  private static func sessionLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
  }

  private func notePause(_ message: String) {
    guard message != pausedNote else { return }
    pausedNote = message
    log(message)
  }

  @MainActor
  func start() async throws {
    locked = Self.sessionLocked()
    asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    if opts.cursor { startCursorTimer() }
    observePower()
    try await resume(initial: true)
  }

  @MainActor
  private func scheduleRetry(after delay: Double = 2) {
    retryWork?.cancel()
    let item = DispatchWorkItem { [weak self] in
      Task { @MainActor in try? await self?.resume(initial: false) }
    }
    retryWork = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  @MainActor
  private func resume(initial: Bool) async throws {
    retryWork?.cancel()
    retryWork = nil
    guard !running, !starting else { return }
    if locked || asleep {
      notePause("capture paused: screen locked or asleep")
      return
    }
    starting = true
    defer { starting = false }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard !locked, !asleep else { return }
    if Self.shouldWaitForDisplay(requested: opts.display, available: content.displays.count) {
      notePause("capture paused: no active display")
      // Displays can appear in SCShareableContent shortly after wake.
      if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { scheduleRetry(after: 2) }
      return
    }
    guard opts.display < content.displays.count else {
      if initial {
        throw NSError(domain: "ascii-screen", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display \(opts.display)"])
      }
      notePause("capture paused: display \(opts.display) unavailable")
      return
    }
    let display = content.displays[opts.display]
    let bounds = CGDisplayBounds(display.displayID)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(Double(display.width) * opts.scale)
    cfg.height = Int(Double(display.height) * opts.scale)
    cfg.minimumFrameInterval = CMTime(seconds: opts.interval, preferredTimescale: 600)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    cfg.queueDepth = 3
    let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await s.startCapture()
    stream = s
    setActiveBounds(bounds)
    pausedNote = ""
  }

  @MainActor
  private func pause() async {
    retryWork?.cancel()
    retryWork = nil
    let active = stream
    stream = nil
    setActiveBounds(nil)
    try? await active?.stopCapture()
    flushHistory()
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
    // Vision autoreleases per call; drain every frame so a long-running service doesn't creep.
    autoreleasepool { if pipeline.process(pb) { emit() } }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    flushHistory()
    if !CGPreflightScreenCaptureAccess() {
      log("capture stopped (permission revoked): \(error.localizedDescription)")
      exit(1)
    }
    Task { @MainActor [weak self] in
      guard let self, self.stream === stream else { return }
      self.stream = nil
      self.setActiveBounds(nil)
      if Self.sessionLocked() { self.locked = true }
      if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { self.asleep = true }
      if self.locked || self.asleep {
        self.notePause("capture paused: screen locked or asleep")
      } else {
        self.notePause("capture paused (\(error.localizedDescription)); waiting for display")
        self.scheduleRetry(after: 5)
      }
    }
  }

  /// The cursor isn't in the captured frames (so moving it wakes nothing); poll it cheaply instead.
  private func startCursorTimer() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + opts.interval, repeating: opts.interval, leeway: .milliseconds(Int(opts.interval * 500)))
    t.setEventHandler { [weak self] in
      guard let self, self.activeBounds() != nil, self.pipeline.imageSize.0 > 0 else { return }
      let cell = self.cursor().map { (jsRound(Double($0.x) * Double(self.opts.width)), jsRound(Double($0.y) * Double(self.pipeline.canvasHeight))) }
      if cell?.0 != self.lastCursorCell?.0 || cell?.1 != self.lastCursorCell?.1 { self.emit() }
    }
    t.resume()
    timer = t
  }

  private func cursor() -> CGPoint? {
    guard opts.cursor, let bounds = activeBounds(), bounds.width > 0, bounds.height > 0,
          let loc = CGEvent(source: nil)?.location, bounds.contains(loc) else { return nil }
    return CGPoint(x: (loc.x - bounds.minX) / bounds.width, y: (loc.y - bounds.minY) / bounds.height)
  }

  private func emit() {
    let c = cursor()
    lastCursorCell = c.map { (jsRound(Double($0.x) * Double(opts.width)), jsRound(Double($0.y) * Double(pipeline.canvasHeight))) }
    sink.emit(cursor: c)
  }

  func flushHistory() {
    sink.flushHistory()
  }

  /// Stop capturing entirely while the screen is locked or asleep.
  @MainActor
  private func observePower() {
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.locked = true; await self?.pause() }
    }
    dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.locked = false
        self?.asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        try? await self?.resume(initial: false)
      }
    }
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.asleep = true; await self?.pause() }
    }
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.asleep = false
        self?.locked = Self.sessionLocked()
        try? await self?.resume(initial: false)
      }
    }
    CGDisplayRegisterReconfigurationCallback({ _, flags, context in
      guard let context, !flags.contains(.beginConfigurationFlag),
            flags.intersection([.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .desktopShapeChangedFlag]) != [] else { return }
      let live = Unmanaged<Live>.fromOpaque(context).takeUnretainedValue()
      Task { @MainActor in
        await live.pause()
        live.asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        live.locked = Live.sessionLocked()
        try? await live.resume(initial: false)
      }
    }, Unmanaged.passUnretained(self).toOpaque())
  }
}

func captureOnce(_ opts: Options) async throws -> Snapshot {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  guard opts.display < content.displays.count else { throw NSError(domain: "ascii-screen", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display \(opts.display)"]) }
  let display = content.displays[opts.display]
  let cfg = SCStreamConfiguration()
  cfg.width = Int(Double(display.width) * opts.scale)
  cfg.height = Int(Double(display.height) * opts.scale)
  cfg.pixelFormat = kCVPixelFormatType_32BGRA
  cfg.showsCursor = false
  let sb = try await SCScreenshotManager.captureSampleBuffer(
    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
  guard let pb = sb.imageBuffer else { throw NSError(domain: "ascii-screen", code: 2) }
  return Snapshot(pixels: pb, bounds: CGDisplayBounds(display.displayID),
                  cursor: opts.cursor ? CGEvent(source: nil)?.location : nil)
}
