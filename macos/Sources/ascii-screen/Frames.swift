import CoreVideo
import Foundation

/// Feeds frames from an external command (e.g. `phoneframes`) into the
/// same pipeline, live file and history as the display stream. The command
/// prints "W H" then W*H*4 bytes of BGRA per frame; the service exits when
/// the command does, so a supervisor can restart it.
final class Frames {
  private let process: Process
  private var reader: FrameReader
  private let pipeline: Pipeline
  private let sink: Sink
  private var signalSources: [DispatchSourceSignal] = []

  init(opts: Options, command: String) throws {
    pipeline = Pipeline(opts)
    let history = opts.history.map { History(dir: URL(fileURLWithPath: $0), keepDays: opts.keepDays) }
    sink = Sink(opts: opts, pipeline: pipeline, output: frameOutput(opts), history: history)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", command]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.standardError
    try proc.run()
    process = proc
    reader = FrameReader(handle: pipe.fileHandleForReading)
  }

  /// Reads frames until the command ends or fails; exits the process like
  /// Live does when its stream stops.
  func run() -> Never {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      src.setEventHandler { [weak self] in
        self?.sink.flushHistory()
        self?.process.terminate()
        exit(0)
      }
      src.resume()
      signalSources.append(src)
    }
    while let pb = reader.next() {
      // Vision autoreleases per call; drain every frame so a long-running
      // service doesn't creep.
      autoreleasepool { if pipeline.process(pb) { sink.emit(cursor: nil) } }
    }
    // A bad header or read error ends the loop while the command may still be
    // blocked on a full pipe; closing our end gives it EPIPE instead of hanging.
    try? reader.handle.close()
    process.waitUntilExit()
    sink.flushHistory()
    log("frame source ended (exit \(process.terminationStatus))")
    exit(process.terminationStatus == 0 ? 0 : 1)
  }
}

/// Reads "W H\n" + W*H*4 BGRA frames from a pipe.
struct FrameReader {
  let handle: FileHandle
  var buffer = Data()

  /// The next frame as a BGRA pixel buffer, or nil at EOF or on a bad header.
  mutating func next() -> CVPixelBuffer? {
    while true {
      // Data indices don't rebase after removeFirst; distance() gives the byte count.
      if let nl = buffer.firstIndex(of: 0x0a) {
        let n = buffer.distance(from: buffer.startIndex, to: nl)
        let line = buffer.prefix(n)
        buffer.removeFirst(n + 1)
        let p = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]),
              w > 0, h > 0, w * h * 4 <= 500_000_000 else { return nil }
        guard fill(w * h * 4) else { return nil }
        let px = buffer.prefix(w * h * 4)
        buffer.removeFirst(w * h * 4)
        return pixelBuffer(width: w, height: h, bgra: px)
      }
      guard let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty else { return nil }
      buffer.append(chunk)
    }
  }

  private mutating func fill(_ n: Int) -> Bool {
    while buffer.count < n {
      guard let chunk = try? handle.read(upToCount: max(1 << 16, n - buffer.count)),
            !chunk.isEmpty else { return false }
      buffer.append(chunk)
    }
    return true
  }
}

func pixelBuffer(width w: Int, height h: Int, bgra px: Data.SubSequence) -> CVPixelBuffer? {
  var pb: CVPixelBuffer?
  let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
  guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
        let pb else { return nil }
  // IOSurface-backed buffers vend no base address until locked.
  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }
  guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
  let rowBytes = CVPixelBufferGetBytesPerRow(pb)
  px.withUnsafeBytes { src in
    guard let s = src.baseAddress else { return }
    for y in 0..<h {
      memcpy(base.advanced(by: y * rowBytes), s.advanced(by: y * w * 4), w * 4)
    }
  }
  return pb
}
