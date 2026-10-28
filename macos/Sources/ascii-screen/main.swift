import CoreGraphics
import CoreVideo
import Foundation

let usage = """
Usage: ascii-screen [options]            live ASCII view of the screen, updated when it changes
       ascii-screen --once [options]     capture the screen once and exit
       ascii-screen --image <file>...    convert an image file (more files = successive frames)
       ascii-screen --at <time>          print the saved frame that was on screen at <time>
                                         (HH:MM[:SS] today, or ISO 8601 like 2026-10-27T14:05:00+07:00)

Options:
  --width <n>          Canvas width (default 160)
  --height <n>         Canvas height (default: from aspect ratio)
  --interval <s>       Minimum seconds between frames (default 1)
  --scale <f>          Capture scale relative to display points (default 1; 2 = Retina pixels)
  --fast               Faster, less accurate OCR
  --correction         OCR language correction (about 2x the CPU, little gain on UI text)
  --no-cursor          Don't draw the pointer
  --full-every <n>     Full-screen OCR after n incremental frames (default 30)
  --no-atlas           OCR each changed region with its own Vision call (default: pack them into one)
  --out <file>         Write each frame atomically to <file> instead of stdout
  --display <i>        Display index (default 0)
  --stats              Log per-frame timing and CPU to stderr
  --history <dir>      Also keep every changed frame, gzip-compressed, in <dir>/YYYY-MM-DD.txt.gz
                       (read with gzcat or --at; saved within 10s of a change and on sleep/lock/exit)
  --keep-days <n>      Delete history files older than n days (default 14; 0 keeps everything)
"""

var opts = Options()
var mode = "live", imagePath = "", images: [String] = [], atTime = ""
var args = CommandLine.arguments.dropFirst().makeIterator()
func value(_ flag: String) -> String {
  guard let v = args.next() else { log("\(flag) needs a value"); exit(2) }
  return v
}
while let a = args.next() {
  switch a {
  case "--width": opts.width = Int(value(a)) ?? opts.width
  case "--height": opts.height = Int(value(a))
  case "--interval": opts.interval = Double(value(a)) ?? opts.interval
  case "--scale": opts.scale = Double(value(a)) ?? opts.scale
  case "--fast": opts.fast = true
  case "--correction": opts.languageCorrection = true
  case "--no-cursor": opts.cursor = false
  case "--full-every": opts.fullEvery = Int(value(a)) ?? opts.fullEvery
  case "--no-atlas": opts.atlas = false
  case "--out": opts.out = value(a)
  case "--display": opts.display = Int(value(a)) ?? 0
  case "--stats": opts.stats = true
  case "--history": opts.history = value(a)
  case "--keep-days": opts.keepDays = Int(value(a)) ?? opts.keepDays
  case "--at": mode = "at"; atTime = value(a)
  case "--once": mode = "once"
  case "--image": mode = "image"; images.append(value(a)); imagePath = images[0]
  case "--detect-json": mode = "detect"; imagePath = value(a)
  case "--render-json": mode = "render"
  case "-h", "--help": print(usage); exit(0)
  default: log("unknown option \(a)\n\n\(usage)"); exit(2)
  }
}

switch mode {
case "image", "detect":
  guard let pb = loadImage(imagePath) else { log("cannot read \(imagePath)"); exit(1) }
  if mode == "detect" {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let lines = detectLines(Bitmap(base: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self),
                                   width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                   rowBytes: CVPixelBufferGetBytesPerRow(pb)))
    print(String(data: try JSONSerialization.data(withJSONObject: lines.map(lineJSON)), encoding: .utf8)!)
    exit(0)
  }
  // Several --image flags are processed as consecutive frames (exercises incremental OCR).
  let p = Pipeline(opts)
  p.process(pb)
  for path in images.dropFirst() {
    guard let next = loadImage(path) else { log("cannot read \(path)"); exit(1) }
    p.process(next)
  }
  print(p.render(cursor: nil))
case "render":
  // Test hook: {"fn": "ascii" | "addLinesToAsciiText", "args": [...]} on stdin, same as ascii.js.
  let req = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
  let a = req["args"] as! [Any]
  let r = req["fn"] as! String == "ascii"
    ? renderAscii((a[0] as! [[String: Any]]).map(obsFrom), (a[1] as! [[String: Any]]).map(lineFrom),
                  a[2] as? Double, a[3] as? Double, a[4] as! Int, a[5] as! Int)
    : addLines(a[0] as! String, (a[1] as! [[String: Any]]).map(lineFrom), a[2] as! Int, a[3] as! Int)
  let out = ["originalText": r.originalText, "linesText": r.linesText, "finalText": r.finalText]
  print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
case "at":
  guard let t = parseTime(atTime) else { log("cannot parse time \(atTime)"); exit(2) }
  let dir = opts.history ?? NSString(string: "~/.ascii-screen/history").expandingTildeInPath
  guard let (when, frame) = try History(dir: URL(fileURLWithPath: dir)).frame(at: t) else {
    log("no saved frame at or before \(History.stamp(t)) in \(dir)"); exit(1)
  }
  log("frame saved at \(History.stamp(when))")
  print(frame)
case "once":
  try checkPermission()
  Task {
    do {
      let p = Pipeline(opts)
      p.process(try await captureOnce(opts))
      print(p.render(cursor: nil))
      exit(0)
    } catch { log("capture failed: \(error.localizedDescription)"); exit(1) }
  }
  RunLoop.main.run()
default:
  try checkPermission()
  setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) // efficiency cores, throttled I/O
  let live = Live(opts)
  var signalSources: [DispatchSourceSignal] = []
  for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { live.flushHistory(); exit(0) }
    src.resume()
    signalSources.append(src)
  }
  Task {
    do { try await live.start() } catch { log("capture failed: \(error.localizedDescription)"); exit(1) }
  }
  RunLoop.main.run()
}

func checkPermission() throws {
  if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    log("Screen Recording permission missing: allow this app (or your terminal) in System Settings > Privacy & Security > Screen Recording.")
    exit(1)
  }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
func obsFrom(_ d: [String: Any]) -> Obs {
  let o = d["origin"] as! [String: Any], s = d["size"] as! [String: Any]
  return Obs(text: d["text"] as! String, x: num(o["x"]), y: num(o["y"]), w: num(s["width"]), h: num(s["height"]))
}
func lineFrom(_ d: [String: Any]) -> DLine {
  let o = obsFrom(d)
  return DLine(vertical: o.text == "|", x: o.x, y: o.y, w: o.w, h: o.h)
}
func lineJSON(_ l: DLine) -> [String: Any] {
  ["text": l.vertical ? "|" : "_", "origin": ["x": l.x, "y": l.y], "size": ["width": l.w, "height": l.h]]
}
