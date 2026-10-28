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
