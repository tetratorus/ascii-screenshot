import Foundation
import LightpinkyCore

/// Uses macOS's paired CoreDevice connection. No separate tunnel or heartbeat owner.
final class IPhone {
  private let opts: Options
  private let device: String
  private let pipeline: Pipeline
  private let sink: Sink
  private var phone: Phone?
  private var controller: FrameReceiver?
  private var sharedAt: Double = 0
  private var signals: [DispatchSourceSignal] = []
  private var lastState = ""

  init(opts: Options, device: String) throws {
    self.opts = opts
    self.device = device
    pipeline = Pipeline(opts)
    let history = opts.history.map { History(dir: URL(fileURLWithPath: $0), keepDays: opts.keepDays) }
    sink = Sink(opts: opts, pipeline: pipeline, output: frameOutput(opts), history: history)
  }

  private func state(_ message: String) {
    if message != lastState { log("iPhone: \(message)"); lastState = message }
  }

  private func connection() throws -> Phone {
    if let phone { return phone }
    let matches = try PhoneInfo.discover().filter {
      $0.id == device || $0.udid == device || $0.name == device
    }
    guard matches.count == 1 else { throw PhoneError("Expected one paired iPhone matching \(device), found \(matches.count)") }
    let connected = Phone(matches[0])
    phone = connected
    return connected
  }

  /// Unknown state is treated as idle. Recording must never wake or unlock a phone.
  static func canCapture(power: [String: Any]) -> Bool {
    power["Locked"] as? Bool == false && power["ScreenOn"] as? Bool == true
  }

  static func pollDelay(interval: Double, elapsed: Double, failures: Int) -> Double {
    if failures>0 {
      // A timed-out command already spent its interval waiting. Back off from
      // completion instead of immediately opening another developer client.
      return max(interval,min(30,5 * pow(2,Double(min(failures-1,3)))))
    }
    // A capture slower than the interval means the link is slow: each frame
    // is a full PNG. Leave the link idle for three times as long as the
    // capture took, so phone control still gets through.
    return elapsed<=interval ? max(0.05,interval-elapsed) : min(15,3*elapsed)
  }

  func run() -> Never {
    let events = DispatchQueue(label: "ascii-screen.iphone.events")
    let flush = DispatchSource.makeTimerSource(queue: events)
    flush.schedule(deadline: .now() + 5, repeating: 5)
    flush.setEventHandler { [sink] in sink.flushHistory() }
    flush.resume()
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: events)
      source.setEventHandler { [sink] in
        sink.flushHistory()
        exit(0)
      }
      source.resume()
      signals.append(source)
    }
    var failures=0
    while true {
      let start = ProcessInfo.processInfo.systemUptime
      var delay = opts.interval
      autoreleasepool {
        var phase = "device connection"
        do {
          let phone = try connection()
          phase = "state read"
          let power = try phone.power()
          guard Self.canCapture(power: power) else {
            failures=0
            state("paused (locked, display off, or state unavailable)")
            delay = max(3, opts.interval)
            return
          }
          // While the phone controller is streaming the display, use its
          // frames: a screenshot would compete with it for the link.
          if controller == nil { controller = try? FrameReceiver(udid: phone.info.udid) }
          let shared = controller?.latest(maxAge: 3)
          let now = ProcessInfo.processInfo.systemUptime
          if shared != nil { sharedAt = now }
          // The controller restarts its stream now and then. Wait out a
          // short gap rather than switch source and re-read the whole
          // screen twice.
          if shared == nil, now - sharedAt < 8 { return }
          phase = "screenshot"
          guard let pixels = pixelBuffer(image: try shared ?? phone.screenshot()) else {
            throw NSError(domain: "IPhone", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot decode screenshot"])
          }
          if pipeline.process(pixels) { sink.emit(cursor: nil) }
          failures=0
          state(shared == nil ? "capturing through CoreDevice (\(device))"
                              : "capturing from the phone controller's video stream")
        } catch {
          phone = nil
          failures=min(failures+1,4)
          state("\(phase) unavailable: \(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
      }
      Thread.sleep(forTimeInterval: Self.pollDelay(interval:delay,
        elapsed:ProcessInfo.processInfo.systemUptime-start,failures:failures))
    }
  }
}
