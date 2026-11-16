import Foundation

/// The live file: atomically rewritten on every change, or stdout when
/// --out is not set (terminal gets cursor-home + clear codes).
func frameOutput(_ opts: Options) -> FrameOutput {
  let tty = isatty(STDOUT_FILENO) != 0
  return FrameOutput { text in
    if let out = opts.out {
      try text.write(toFile: out, atomically: true, encoding: .utf8)
    } else {
      try FileHandle.standardOutput.write(contentsOf: Data(((tty ? "\u{1B}[H\u{1B}[2J" : "") + text + (tty ? "" : "\n\u{0C}\n")).utf8))
    }
  }
}

final class FrameOutput {
  private var lastText: String?
  private let write: (String) throws -> Void

  init(write: @escaping (String) throws -> Void) {
    self.write = write
  }

  @discardableResult
  func emit(_ text: String) throws -> Bool {
    guard text != lastText else { return false }
    try write(text)
    lastText = text
    return true
  }
}
