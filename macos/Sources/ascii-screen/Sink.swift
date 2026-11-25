import CoreGraphics
import Foundation

/// Writes each changed frame to the live file and history; shared by the
/// display stream and external frame sources.
final class Sink {
  private let opts: Options
  private let pipeline: Pipeline
  private let output: FrameOutput
  private let history: History?
  private var lastSaved: Frame?
  private let lock = NSLock()

  init(opts: Options, pipeline: Pipeline, output: FrameOutput, history: History?) {
    self.opts = opts
    self.pipeline = pipeline
    self.output = output
    self.history = history
  }

  func emit(cursor: CGPoint?) {
    lock.lock()
    defer { lock.unlock() }
    let frame = pipeline.frame(cursor: cursor)
    let text = frame.render(columns: opts.width, rows: pipeline.canvasHeight, fit: opts.fit, cellAspect: opts.cellAspect)
    let shown: Bool
    do { shown = try output.emit(text) } catch {
      log("cannot write ASCII output: \(error.localizedDescription)")
      exit(1)
    }
    // Also save text changes too small to show at this grid: history can be drawn bigger later.
    guard shown || lastSaved.map({
      $0.width != frame.width || $0.height != frame.height || $0.obs != frame.obs || $0.lines != frame.lines
    }) ?? true else { return }
    lastSaved = frame
    do { try history?.record(frame.encode()) } catch { log("cannot write history: \(error.localizedDescription)") }
  }

  func flushHistory() {
    lock.lock()
    defer { lock.unlock() }
    do { try history?.flush() } catch { log("cannot write history: \(error.localizedDescription)") }
  }
}
