# Emulator results: non-root accessibility capture + OCR (2026-11-10)

**Verdict:** on a stock, non-root Google Play Android 16 (API 36) emulator, an ordinary
app enabled through Accessibility Settings captures screen pixels from other apps
about once per second and OCRs Chinese and English text from them. Screen capture
keeps the 1 s pace. Every changed frame is now OCRed, in order, with none dropped
(see "Lossless queue, any-size models, rotation" at the end). Raw evidence is in
[research/emulator-2026-11-10/](research/emulator-2026-11-10/).

Not proven here: any physical phone, battery/heat, OEM background killing, or GPU/NPU OCR.

## Setup

| Check | Result |
|---|---|
| Host | Ubuntu x86_64, `/dev/kvm` |
| Image | `system-images;android-36;google_apis_playstore;x86_64`, 1080x2424, 4 vCPU |
| Build | `google/sdk_gphone64_x86_64/emu64xa:16/BE2A.250530.026.D1/13818094:user/release-keys` |
| SELinux | `Enforcing` |
| `ro.debuggable` | `0`; `adb root` rejected: "adbd cannot run as root in production builds" |
| ADB shell | `uid=2000(shell)` |
| App | ordinary install, `uid:10217` |
| Permission | enabled in Settings > Accessibility > AsciiScreen capture, normal "full control" disclosure ([shot](research/emulator-2026-11-10/shots/01-disclosure.png)); no `settings put` used |

Emulator command: `emulator -avd capture36 -no-snapshot -no-audio -gpu swiftshader_indirect -no-boot-anim -memory 4096 -cores 4`.
Sideloaded APK was not blocked by restricted settings on this image.

## Code change

The original service took a screenshot, ran OCR on it, and only then scheduled the
next screenshot. With ~3 s OCR that gave one frame every ~4 s while claiming 1 fps.
`CaptureService` now:

- captures on a fixed 1 s clock on its own thread and hands every changed frame, in
  order, to a separate OCR thread (see "Incremental OCR" below). No frame is dropped
  (see the last section);
- logs `capture_ms`, `ocr_ms`, and `lag_ms` (capture to OCR result) separately;
- logs a slot as `missed_slot: in_flight` while a screenshot request is outstanding,
  times requests out after 5 s (`SCREENSHOT_TIMEOUT`), drops late results of
  timed-out requests (`LATE_SCREENSHOT_DROPPED`), and keeps 400 ms between requests
  (Android rejects requests closer than 333 ms with error 3);
- pauses on `SCREEN_OFF`, resumes on `SCREEN_ON`;
- on destroy, logs `SERVICE_DESTROYED` immediately, reads any frames still waiting,
  logs `OCR_DRAINED`, then closes the models and log.

A debug-only `SecureFixtureActivity` (FLAG_SECURE window with English + Chinese text)
is added for the secure-window test. It is not in release builds.

## Results

| # | Test | Result |
|---|---|---|
| 1 | Non-root setup | Pass, see table above |
| 2 | Pixels + OCR from other apps | Pass. Launcher ("Gmail \| Photos \| YouTube \| Play Store"), Settings ("Search Settings \| Network & internet"), Chrome fixture ("今日新闻 Daily News", "新加坡天气：晴，最高温度32度。", "Meeting with GovTech at 3pm about OCR capture."), lock screen ("T-Mobile \| Tue, Nov 10"). Text changes as pages scroll. |
| 3 | Cadence | Pass for capture, not for OCR. See below. |
| 4 | Background / swipe from recents | Pass. Capture and OCR of launcher and Chrome continued after leaving the app and swiping it out of recents. One screenshot request hung ~5 s during the switch into Chrome (4 missed slots, then `SCREENSHOT_TIMEOUT`), then capture recovered by itself. |
| 5 | Real PIN lock | Pass. Screen off: `SCREEN_OFF`, no capture for 62 s. Screen on: lock screen captured and OCRed. PIN pad came back blank (OCR found no text). After unlock, Chrome OCR resumed with no new consent prompt. |
| 6 | FLAG_SECURE | Blocked, as Android intends. Fixture text never appeared; only the status bar was OCRed. `adb screencap` also shows black ([shot](research/emulator-2026-11-10/shots/04-secure-adb-screencap.png)). No bypass attempted. |
| 7a | Disable / re-enable in Settings | Pass. Disable: service unbound, `SERVICE_DESTROYED`. Re-enable with the same disclosure: `SERVICE_CONNECTED`, capture resumed. |
| 7b | Reboot | Pass after first unlock. Before first unlock the service stays enabled but unbound (app is not direct-boot aware, so nothing is captured). After the PIN is entered it binds and captures without user action. |
| 7c | Reinstall (`adb install -r`) | Service stayed enabled and rebound by itself. |

### Cadence (127 s uninterrupted run, new build)

Launcher 20 s, Chrome fixture 30 s (contains a counter that changes every second), 6 scrolls, Settings 20 s, secure fixture 15 s, launcher 15 s
([measure-window.jsonl](research/emulator-2026-11-10/measure-window.jsonl)).

| Metric | min | median | p95 | max |
|---|---|---|---|---|
| Gap between screenshots (s) | 0.49 | 1.00 | 1.03 | 1.31 |
| Screenshot time `capture_ms` | 38 | 49 | 171 | 597 |
| OCR time `ocr_ms` | 1476 | 2921 | 3797 | 3865 |
| Capture to text `lag_ms` | 1888 | 3287 | 4429 | 4778 |

129 screenshots, 0 errors, 0 missed slots. 70 changed frames, 28 OCRed, 42 superseded.
OCR is LiteRT on 4 CPU threads in an emulator. The earlier Samsung NPU profile (about
6 ms per detector run, 4 ms per line) suggests real-phone OCR could run well under 1 s,
but that has not been measured end to end on a phone.

The run above is the first build (full-screen OCR on the newest frame). It was
replaced by the incremental OCR below.

## Incremental OCR (port of the macOS pipeline)

`Pipeline.java` ports `macos/Sources/ascii-screen/Pipeline.swift`: keep the text already
read, diff each frame against the previous one in 32 px tiles, and only read what changed.

- **Change inside a line already read** (a counter, a clock): that line is re-recognised
  directly; the detector does not run.
- **Other changes**: the changed regions are grown until no cached line straddles an
  edge, packed into one image as wide as the screen, and the detector runs once on it.
  Padding is trimmed back off cached lines that the changed pixels don't touch, so a
  scrollbar or caret beside text doesn't make that text be re-read.
- **Scroll**: a vertical shift is found by matching row slices; cached lines move with the
  page and only newly revealed rows (and anything that changed on top) are read.
- **Full re-read** every 30 frames, when changes cover more than half the screen, or when
  the screen size changes.
- Every changed frame is read in order (first version dropped frames past a backlog
  of 4; that is gone, see the last section).

Each OCR log line now records `mode` (`full`, `regions`, `reread`, `scroll+...`),
`rects`, `area_pct`, `scroll_dy`, `moved`, `backlog`, and a time breakdown `ms` =
[resize, detector input, detector, detector postprocess, recogniser input, recogniser].

The rest of this section describes the first incremental build (fixed-size TFLite models).
Where the time goes on this emulator (from `ms`): the detector costs ~500 ms per pass and
a full 1080x2424 screen needs two passes; each line costs ~60-80 ms to recognise. The
detector has a fixed 1280x608 input (its upsampling layers have constant sizes, so LiteRT
cannot resize it), so a small change still pays one ~500 ms pass unless it can skip the
detector.

| Workload | Before (full screen, newest frame) | After (incremental) |
|---|---|---|
| Chrome page with a counter ticking every second, 60 s | 28 of 70 changed frames read, median 2.9 s each | 60 of 60 read, 0 dropped; median 138 ms (counter re-read only), lag median 145 ms |
| 10 fast swipes (~750 px each, 1.5 s apart), then launcher, Settings, back to Chrome | n/a | 41 of 46 changed frames read before the backlog limit, 8 dropped (logged); scroll frames read only the revealed ~32% of the screen in 1.5-3 s |

([incremental-counter.jsonl](research/emulator-2026-11-10/incremental-counter.jsonl),
[incremental-scroll-switch.jsonl](research/emulator-2026-11-10/incremental-scroll-switch.jsonl),
[fixture-scroll.html](research/emulator-2026-11-10/fixture-scroll.html))

On the emulator CPU, continuous fast scrolling and page loads (full re-reads at 2.5-5 s)
still outrun 1 fps and cause drops. Text that is actually new has to go through the
detector, so the remaining fix is a cheaper detector pass: a GPU/NPU delegate, or an
extra detector exported at a smaller input size for small regions. Neither is done yet.
The 30-frame full re-read (about 3.4 s here) builds a 3-frame backlog that clears within
a few seconds.

## Lossless queue, any-size models, rotation

**No dropped frames.** A waiting frame is stored as only its changed 32 px tiles
(`FramePatch.java`), not a full 10 MB copy. Waiting patches stay in memory up to 48 MB,
then go to app-private files (`no_backup/backlog/`) and are read back in order. The OCR
thread rebuilds each frame from the previous one plus the patch. If a spilled patch can't
be read back, that frame is logged as `frame_lost` and the next capture is sent whole;
this never happened in testing. At shutdown, waiting frames are read before the models
close. Capture log lines now include `changed_tiles`, `queued`, `queued_kb`, `spilled`.

**Models of any size.** The fixed sizes came from the TFLite conversion, which bakes the
example input size into the graph; the official PaddlePaddle ONNX exports of the same
PP-OCRv6 small models take any size. The app now runs those on ONNX Runtime 1.22 for
Android (`com.microsoft.onnxruntime:onnxruntime-android`), 4 CPU threads:

- The detector runs on exactly the image it is given: the whole screen in either
  orientation, scaled so the short side is 608 px, or just the packed atlas of changed
  regions. A small change now costs a small pass instead of a full 1280x608 one.
- Lines are recognised at their natural width instead of padded to 640, and several
  lines go through the recogniser in one call (sorted by width, up to 8 per call).
- Same dictionary; the text output is the same quality as before.

**Rotation.** A new screen size (portrait <-> landscape) forces a full re-read at the new
size; cached text is discarded and the patch for that frame is the whole frame. The
detector reads landscape at full width (boxes out to x=2375 on the 2424x1080 screen)
instead of squashing it into a tall input.

| Workload (same emulator) | Fixed-size TFLite | Any-size ONNX, lossless queue |
|---|---|---|
| Full screen read | median 2.9 s | 0.6-1.3 s typical, 3.3 s max (busy Chrome/Settings screens) |
| Counter line re-read | median 138 ms | median 43 ms |
| 10 fast swipes, launcher, Settings, Chrome, rotate to landscape, swipe, rotate back, rotate the other way, back | 8 of 46 frames dropped (first incremental build, no rotation) | 85 of 85 changed frames read, 0 dropped, 0 errors; backlog peaked at 7 frames / 44 MB; lag median 56 ms, max 8.1 s |
| Same swipes with the memory budget cut to 1 MB (test build) | n/a | 18 of 18 read, 3 went through disk and back, 0 lost |

Per mode in the swipe/rotation run: `reread` median 43 ms, `regions` median 421 ms,
`scroll+regions` median 733 ms, `full` median 970 ms.
([lossless-scroll-switch-rotate.jsonl](research/emulator-2026-11-10/lossless-scroll-switch-rotate.jsonl),
[lossless-spill-1mb.jsonl](research/emulator-2026-11-10/lossless-spill-1mb.jsonl),
[lossless-counter-start.jsonl](research/emulator-2026-11-10/lossless-counter-start.jsonl))

Superseded below: waiting frames are now read together, and the APK is smaller.

## Waiting frames read together, smaller APK

**Shared passes.** When frames are waiting, the OCR thread takes up to 4 of them at once
(`Pipeline.processAll`). It works out each frame's changes in order, as before. Regions
from different frames that don't touch go into one detector call, and every line that
needs reading, from all of those frames, goes through the recogniser together (up to 8
per call). A frame has to wait for an earlier frame's detector pass only when its change
touches a region that earlier frame is still reading, scrolls, or needs a full read; then
the earlier frames' detector pass runs first. Text is still read once at the end for the
whole group. Each frame keeps its own result: a line found in frame 2 is not in frame 1's
output, and a line erased in frame 2 is still in frame 1's. Unit tests cover all three cases.

Re-run of the same scenario on this build (counter 30 s, 10 fast swipes, launcher,
Settings, Chrome, four rotations), [batch-scroll-switch-rotate.jsonl](research/emulator-2026-11-10/batch-scroll-switch-rotate.jsonl):

- 106 screenshots, 57 changed, 57 read, none missing, no errors or lost frames.
- Backlog peaked at 4 frames / 31 MB, nothing spilled to disk. Lag median 102 ms, max 12.5 s
  (during the swipe burst), caught up afterwards.
- Single-frame timings: `reread` median 60 ms, `full` median 0.9 s (max 3.3 s).
- Groups of 2-4 waiting frames were read together 16 times. In this run every waiting
  frame was either a full read (fast flings move more than half the screen between
  frames) or touched the previous frame's region, so detector passes were not actually
  shared; recogniser batches were. Shared detector passes help when separate parts of the
  screen gain new text in consecutive frames while a backlog exists.

**APK size.** Only the arm64 (phones) and x86_64 (emulator) ONNX Runtime libraries are
packaged now: 109 MB -> 74 MB. A phone-only build would drop x86_64 for about 52 MB.

**Faster CPU path tried: XNNPACK.** Turning on ONNX Runtime's XNNPACK backend crashed the
app on its first OCR call on the x86_64 emulator (native SIGSEGV inside
`libonnxruntime.so`, OCR thread). It is not enabled. Not tried on arm64. The crash also
showed that a native crash kills the capture service and Android waits 30 minutes before
restarting it, so a crashing model takes capture down with it.

**Lock, secure window, disable, reboot re-run on this build** (09:26-09:30 UTC,
[lifecycle-notes.txt](research/emulator-2026-11-10/lifecycle-notes.txt),
[lifecycle-after-reboot.jsonl](research/emulator-2026-11-10/lifecycle-after-reboot.jsonl);
disable/re-enable this time via `settings put secure enabled_accessibility_services`
rather than the Settings UI):

| Test | Result |
|---|---|
| PIN lock | Pass. Screen off 30 s: `SCREEN_OFF`, no captures. Screen on: lock screen read ("T-Mobile \| Tue, Nov 10"). PIN pad: captured blank, no text ([adb screencap](research/emulator-2026-11-10/shots/lc-bouncer.png) is also black). After the PIN, Chrome reading resumed in the same running service. |
| FLAG_SECURE | Blocked as intended. One frame caught Chrome while the secure screen was opening; after that only the status bar was read. |
| Disable / re-enable | Pass. Disable: `SERVICE_DESTROYED`, then `OCR_DRAINED lost 0` (waiting frames read before shutdown). Re-enable: `SERVICE_CONNECTED`, launcher and Chrome read. |
| Reboot | Pass after first unlock. Before unlock: service not bound, nothing captured. After the PIN: bound and capturing with no user action. The first screenshot after boot timed out (5 s, `SCREENSHOT_TIMEOUT`, 5 one-second slots missed while it was pending); the next 11 s of frames were read late as the phone settled. |

Every changed frame in each service run was read (30/30, 11/11, 12/12), no `frame_lost`.

## Testing gotcha

`adb shell uiautomator dump` (used to find buttons to tap) temporarily disconnects
every accessibility service. Each call shows up in the log as `SERVICE_DESTROYED` +
`SERVICE_CONNECTED`. Several such restarts in the 06:17-06:22 part of
`capture-full.jsonl` come from this, not from the app. The cadence run above used
only `input`/`am start`. Before the 400 ms minimum gap was added, one request landed
less than 333 ms after the previous one right after such a restart (screenshot
`error 3`, 06:22:23).

## Not tested

- Any physical phone, OEM battery/background policy, heat, battery drain.
- GPU/NPU (ONNX Runtime has NNAPI/QNN options; none is wired in, and the emulator could not test it anyway). XNNPACK crashed on the emulator (see above).
- Long runs (longest continuous run here was a few minutes).
- Capture while the lock screen stays on for long periods, or with notifications arriving.
