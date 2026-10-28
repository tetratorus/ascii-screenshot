import CoreGraphics
import CoreVideo
import Foundation

let usage = """
Usage: ascii-screen [options]            live ASCII view of the screen, updated when it changes
       ascii-screen --once [options]     capture the screen once and exit
       ascii-screen --image <file>...    convert an image file (more files = successive frames)
       ascii-screen --at <time>          print the saved frame that was on screen at <time>
                                         (<time>: how long ago like 30s, 5m, 1h30m; HH:MM[:SS] today;
                                          now; or ISO 8601 like 2026-10-27T14:05:00+07:00)
       ascii-screen --play [--from <time>] [--to <time>] [--speed <x>]
                                         replay saved history in the terminal like a screen recording
                                         (default: today so far at 10x; keys: space pause, left/right step,
                                         up/down or +/- speed, q quit)
       ascii-screen --search <query> [--from <time>] [--to <time>] [--limit <n>] [--json]
                                         when matching text was on screen, newest first (default: all history,
                                         20 results). Plain words match in any order and as word starts; also
                                         SQLite FTS5 syntax: invo*, a OR b, NOT, "exact phrase"

Options:
  --width <n>          Canvas width (default 160)
  --height <n>         Canvas height (default: from aspect ratio)
  --interval <s>       Minimum seconds between frames (default 1)
  --scale <f>          Capture scale relative to display points (default 1; 2 = Retina pixels)
  --fast               Faster, less accurate OCR
  --correction         OCR language correction (about 2x the CPU, little gain on UI text)
  --auto-language      Detect the language of each read instead of English only (Chinese, Japanese,
                       Korean, Thai, Russian, Arabic, ...; ~15% more CPU, ~90MB more memory)
  --no-cursor          Don't draw the pointer
  --full-every <n>     Full-screen OCR after n incremental frames (default 30)
  --no-atlas           OCR each changed region with its own Vision call (default: pack them into one)
  --out <file>         Write each frame atomically to <file> instead of stdout
  --display <i>        Display index (default 0)
  --stats              Log per-frame timing and CPU to stderr
  --history <dir>      Also keep every changed frame, gzip-compressed, in <dir>/YYYY-MM-DD.txt.gz
                       (read with gzcat or --at; saved within 10s of a change and on sleep/lock/exit)
  --keep-days <n>      Delete history files older than n days (default 365; 0 keeps everything)
  --from/--to <time>   Playback range (default: midnight today to now)
  --speed <x>          Playback speed (default 10)
  --max-gap <s>        Longest real-time pause between played frames (default 2)
"""

var opts = Options()
var mode = "live", imagePath = "", images: [String] = [], atTime = ""
var fromTime: String?, toTime: String?, speed = 10.0, maxGap = 2.0, query = "", limit = 20, json = false
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
  case "--auto-language": opts.autoLanguage = true
  case "--no-cursor": opts.cursor = false
  case "--full-every": opts.fullEvery = Int(value(a)) ?? opts.fullEvery
  case "--no-atlas": opts.atlas = false
  case "--out": opts.out = value(a)
  case "--display": opts.display = Int(value(a)) ?? 0
  case "--stats": opts.stats = true
  case "--history": opts.history = value(a)
  case "--keep-days": opts.keepDays = Int(value(a)) ?? opts.keepDays
  case "--at": mode = "at"; atTime = value(a)
  case "--play": mode = "play"
  case "--search": mode = "search"; query = value(a)
  case "--json": json = true
  case "--limit": limit = Int(value(a)).flatMap { $0 > 0 ? $0 : nil } ?? limit
  case "--from": fromTime = value(a)
  case "--to": toTime = value(a)
  case "--speed": speed = Double(value(a)).flatMap { $0 > 0 ? $0 : nil } ?? speed
  case "--max-gap": maxGap = Double(value(a)) ?? maxGap
  case "--once": mode = "once"
  case "--image": mode = "image"; images.append(value(a)); imagePath = images[0]
  case "-h", "--help": print(usage); exit(0)
  default: log("unknown option \(a)\n\n\(usage)"); exit(2)
  }
}

func invalid(_ m: String) -> Never { log(m); exit(2) }
if !(1...1000).contains(opts.width) { invalid("--width must be 1-1000") }
if let h = opts.height, !(1...1000).contains(h) { invalid("--height must be 1-1000") }
if !(opts.interval >= 0.1 && opts.interval <= 3600) { invalid("--interval must be 0.1-3600 seconds") }
if !(opts.scale > 0 && opts.scale <= 4) { invalid("--scale must be above 0 and at most 4") }
if opts.display < 0 { invalid("--display must be 0 or more") }
if opts.fullEvery < 0 { invalid("--full-every must be 0 or more") }
if opts.keepDays < 0 { invalid("--keep-days must be 0 or more") }
if !(maxGap >= 0) { invalid("--max-gap must be 0 or more") }
// Frames and history hold whatever was on screen; keep everything we create private to this user.
umask(0o077)

func time(_ s: String?, _ fallback: Date) -> Date {
  guard let s else { return fallback }
  guard let t = parseTime(s) else { log("cannot parse time \(s)"); exit(2) }
  return t
}

switch mode {
case "image":
  guard let pb = loadImage(imagePath) else { log("cannot read \(imagePath)"); exit(1) }
  // Several --image flags are processed as consecutive frames (exercises incremental OCR).
  let p = Pipeline(opts)
  p.process(pb)
  for path in images.dropFirst() {
    guard let next = loadImage(path) else { log("cannot read \(path)"); exit(1) }
    p.process(next)
  }
  print(p.render(cursor: nil))
case "at":
  guard let t = parseTime(atTime) else { log("cannot parse time \(atTime)"); exit(2) }
  let dir = opts.history ?? NSString(string: "~/.ascii-screen/history").expandingTildeInPath
  guard let (when, frame) = History(dir: URL(fileURLWithPath: dir)).frame(at: t) else {
    log("no saved frame at or before \(History.stamp(t)) in \(dir)"); exit(1)
  }
  log("frame saved at \(History.stamp(when))")
  print(frame)
case "search":
  let from = time(fromTime, .distantPast), to = time(toTime, Date())
  let dir = opts.history ?? NSString(string: "~/.ascii-screen/history").expandingTildeInPath
  let matches: [History.Match]
  do { matches = try History(dir: URL(fileURLWithPath: dir)).search(query, from: from, to: to, limit: limit) } catch {
    log("search failed: \(error.localizedDescription)"); exit(2)
  }
  guard !matches.isEmpty else { log("\"\(query)\" not found in saved history in \(dir)"); exit(1) }
  for m in matches where json {
    let o: [String: Any] = ["start": History.stamp(m.start), "end": History.stamp(m.end), "frames": m.frames, "line": m.line]
    print(String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
  }
  for m in matches where !json {
    let span = (m.end > m.start ? " to \(History.stamp(m.end))" : "") + (m.frames > 1 ? "  (\(m.frames) frames)" : "")
    print("\(History.stamp(m.start))\(span)\n    \(m.line.prefix(160))")
  }
case "play":
  let from = time(fromTime, Calendar.current.startOfDay(for: Date())), to = time(toTime, Date())
  let dir = opts.history ?? NSString(string: "~/.ascii-screen/history").expandingTildeInPath
  var player = Playback(frames: History(dir: URL(fileURLWithPath: dir)).frames(from: from, to: to),
                        speed: speed, maxGap: maxGap)
  guard player.frame(0) != nil else {
    log("no saved frames between \(History.stamp(from)) and \(History.stamp(to)) in \(dir)"); exit(1)
  }
  player.run()
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
  for sig in [SIGTERM, SIGINT, SIGHUP] {
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
