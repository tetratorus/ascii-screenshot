import Foundation

/// Uses macOS's paired CoreDevice connection. No separate tunnel or heartbeat owner.
final class IPhone {
  private let opts: Options
  private let device: String
  private let pipeline: Pipeline
  private let sink: Sink
  private let directory: URL
  private var signals: [DispatchSourceSignal] = []
  private var lastState = ""

  init(opts: Options, device: String) throws {
    self.opts = opts
    self.device = device
    pipeline = Pipeline(opts)
    let history = opts.history.map { History(dir: URL(fileURLWithPath: $0), keepDays: opts.keepDays) }
    sink = Sink(opts: opts, pipeline: pipeline, output: frameOutput(opts), history: history)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("ascii-iphone-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
  }

  private func state(_ message: String) {
    if message != lastState { log("iPhone: \(message)"); lastState = message }
  }

  private func command(_ arguments: [String]) throws -> [String: Any] {
    let result = directory.appendingPathComponent("result.json")
    let diagnostics = directory.appendingPathComponent("command.log")
    try? FileManager.default.removeItem(at: result)
    FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
    let output = try FileHandle(forWritingTo: diagnostics)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["devicectl"] + arguments + [
      "--device", device, "--quiet", "--timeout", "8", "--json-output", result.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    // Bound even a stuck devicectl/XPC invocation; never accumulate blocked children.
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.2)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let data = try? Data(contentsOf: result),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["result"] as? [String: Any] else {
      let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
      throw NSError(domain: "IPhone", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(detail.suffix(1200))])
    }
    return payload
  }

  /// Unknown state is treated as idle. Recording must never wake or unlock a phone.
  static func canCapture(lock: [String: Any], displays: [String: Any]) -> Bool {
    let light = displays["backlightState"] as? String ?? ""
    return lock["passcodeRequired"] as? Bool == false && ["on", "activeOn"].contains(light)
  }

  static func pollDelay(interval: Double, elapsed: Double, failures: Int) -> Double {
    if failures>0 {
      // A timed-out command already spent its interval waiting. Back off from
      // completion instead of immediately opening another developer client.
      return max(interval,min(30,5 * pow(2,Double(min(failures-1,3)))))
    }
    return max(0.05,interval-elapsed)
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
      source.setEventHandler { [sink, directory] in
        sink.flushHistory()
        try? FileManager.default.removeItem(at: directory)
        exit(0)
      }
      source.resume()
      signals.append(source)
    }
    let image = directory.appendingPathComponent("screen.png")
    var failures=0
    while true {
      let start = ProcessInfo.processInfo.systemUptime
      var delay = opts.interval
      autoreleasepool {
        do {
          let lock = try command(["device", "info", "lockState"])
          if lock["passcodeRequired"] as? Bool != false {
            failures=0
            state("paused (locked or lock state unavailable)")
            delay = max(3, opts.interval)
            return
          }
          let displays = try command(["device", "info", "displays"])
          guard Self.canCapture(lock: lock, displays: displays) else {
            failures=0
            state("paused (display off or display state unavailable)")
            delay = max(3, opts.interval)
            return
          }
          defer { try? FileManager.default.removeItem(at: image) }
          _ = try command(["device", "capture", "screenshot", "--destination", image.path])
          guard let pixels = loadImage(image.path) else {
            throw NSError(domain: "IPhone", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot decode screenshot"])
          }
          if pipeline.process(pixels) { sink.emit(cursor: nil) }
          failures=0
          state("capturing through CoreDevice (\(device))")
        } catch {
          failures=min(failures+1,4)
          state("connection unavailable: \(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
      }
      Thread.sleep(forTimeInterval: Self.pollDelay(interval:delay,
        elapsed:ProcessInfo.processInfo.systemUptime-start,failures:failures))
    }
  }
}
