# Emulator results: non-root accessibility capture + OCR (2026-11-10)

**Verdict:** on a stock, non-root Google Play Android 16 (API 36) emulator, an ordinary
app enabled through Accessibility Settings captures screen pixels from other apps
about once per second and OCRs Chinese and English text from them. Screen capture
keeps the 1 s pace. Full-screen OCR on the emulator CPU takes about 3 s, so only
about one changed frame in three gets OCRed. Raw evidence is in
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
  order, to a separate OCR thread (see "Incremental OCR" below). If OCR falls more than
  4 frames behind, the oldest waiting frame is dropped and logged as `ocr_dropped_frame`;
- logs `capture_ms`, `ocr_ms`, and `lag_ms` (capture to OCR result) separately;
- logs a slot as `missed_slot: in_flight` while a screenshot request is outstanding,
  times requests out after 5 s (`SCREENSHOT_TIMEOUT`), drops late results of
  timed-out requests (`LATE_SCREENSHOT_DROPPED`), and keeps 400 ms between requests
  (Android rejects requests closer than 333 ms with error 3);
- pauses on `SCREEN_OFF`, resumes on `SCREEN_ON`;
- on destroy, logs `SERVICE_DESTROYED` immediately and discards the result of any OCR
  pass still running, then closes the models and log.

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
- Every changed frame is read in order. Frames are only dropped when more than 4 are
  waiting (each waiting frame is a ~10 MB copy), and every drop is logged.

Each OCR log line now records `mode` (`full`, `regions`, `reread`, `scroll+...`),
`rects`, `area_pct`, `scroll_dy`, `moved`, `backlog`, and a time breakdown `ms` =
[resize, detector input, detector, detector postprocess, recogniser input, recogniser].

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
- GPU/NPU delegate (none is wired in; the emulator could not test it anyway).
- Long runs (longest continuous run here was a few minutes).
- Capture while the lock screen stays on for long periods, or with notifications arriving.
