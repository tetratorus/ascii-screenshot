# ASCII Screenshot

A simple tool to generate an ASCII-like version of images, optimized for screenshots. It also includes basic line detection to enhance the ASCII output.

## Features
- Converts images to ASCII-like art.
- Optimized for screenshots.
- Detects straight UI boundaries: rules, table cells, filled panels and cards.
- Works best with images sized around **1600x1000 pixels**.

## Installation
Install the package via npm:

```bash
npm install -g ascii-screenshot
```

## Usage
Run the tool from the command line, specifying the path to your image:

```bash
ascii-screenshot path/to/img
```

## Requirements
- **macOS only**: This tool uses `osascript` for some functionalities.
- Ensure your image resolution is close to **1600x1000** for best results.

## Live screen mode (macOS, battery-friendly)

`macos/` is a native Swift binary that keeps an ASCII view of your screen up to date, refreshing at most once per `--interval` (default 1s). It is built to keep CPU, and so battery drain, as low as possible:

- **Change-driven.** ScreenCaptureKit only hands over a frame when something on screen changed, so a static screen costs ~0 CPU. Frames that are pixel-identical to the last one are dropped after a `memcmp`.
- **Incremental OCR.** Changed 32px tiles are grouped into regions, grown so no cached word straddles an edge, and only those regions are re-OCRed (Vision `regionOfInterest`); the rest of the text is reused. A full OCR runs when over half the screen changed, and every 30 incremental frames (`--full-every`).
- **Scrolling reuses text.** When a change looks like a vertical scroll (rows of the old frame reappear shifted), the cached text moves with the page and only newly revealed rows, plus anything that changed on top of the scroll, are read. Every frame is still read; on the VM, reading-speed scrolling of a Wikipedia article went from ~1.5s to ~0.9s CPU per frame. Page-sized jumps reveal mostly new text, so they cost about the same as before.
- **One Vision call per frame.** Each Vision call has a large fixed cost (~50–70ms CPU even on a tiny crop), so when several separate regions change they are copied into one packed image and read in a single call (`--no-atlas` to disable). Benchmarks: `macos/benchmarks/OCR.md`.
- **No language correction by default.** On UI text it barely changes the output and costs ~2x the CPU (`--correction` turns it back on). `--fast` is cheaper still but much worse on small UI text.
- **In-process, in memory.** Capture, line detection and rendering run in one process on the captured buffer: no `screencapture`/`osascript`/node per frame, and no PNG encode/decode. Line detection takes ~5ms natively vs ~150ms in JS.
- **Low priority.** The process runs as a Darwin background process (efficiency cores, throttled I/O), and capture stops while the screen is locked or asleep.
- **Cheap cursor.** The pointer is left out of captured frames so moving it doesn't trigger a capture; its position is polled once per interval and only re-renders text (no OCR).

Measured on an M4 VM (1600x1200), CPU time per refresh:

| | CPU per refresh |
| --- | --- |
| `screencapture` + `node index.js` | ~2.0s (whole pipeline, every second) |
| Live mode, nothing changed | ~0 (no frame delivered) |
| Live mode, small change (clock, typing) | ~0.1–0.3s |
| Live mode, whole screen changed | ~0.75s |

```bash
cd macos && swift build -c release
.build/release/ascii-screen                      # live view in the terminal
.build/release/ascii-screen --out /tmp/screen.txt  # atomically rewrite a file on each change
.build/release/ascii-screen --once               # one capture
.build/release/ascii-screen --image shot.png     # convert a file
.build/release/ascii-screen --stats              # per-frame timing/CPU on stderr
.build/release/ascii-screen --history ~/screen-history   # also keep every changed frame, compressed
.build/release/ascii-screen --at 14:05           # print what was on screen at 14:05 today
.build/release/ascii-screen --play --from 14:00   # replay history from 14:00 like a screen recording
.build/release/ascii-screen --last 1m --speed 1          # replay the last minute in real time
```

With `--history <dir>`, every frame that differs from the previous one is kept in `<dir>/YYYY-MM-DD.txt.gz`. Each record is a `@@ <ISO 8601 time>` line followed by the frame. Consecutive frames are nearly identical, so gzip shrinks them about 25x (roughly 400 bytes per frame). Frames are held in memory for at most 10 seconds and then written as one batch, and also when the screen sleeps or locks or the process stops. A crash loses at most the last 10 seconds, and the disk isn't touched on every change. Files older than `--keep-days` (default 14) are deleted. Read history with `gzcat <dir>/2026-10-27.txt.gz | less`, search it with `gzcat ... | grep`, or print the frame shown at a given time with `--at`. Times can be how long ago (`30s`, `5m`, `1h30m`, `2d`), `HH:MM[:SS]` today, `now`, or a full ISO 8601 time.

`--play` replays saved history in the terminal like a screen recording. `--from` and `--to` take the same time formats (default: midnight today to now), and `--last 5m` is short for `--play --from 5m`. Frames are shown at their recorded spacing sped up by `--speed` (default 10x), and idle stretches are capped at `--max-gap` seconds (default 2). While it plays: space pauses, left/right steps one frame, up/down or +/- doubles or halves the speed, and q quits. Frames are cropped to the terminal size, so widen the terminal to see a full 160-column frame. When stdout isn't a terminal it prints the records in `@@ <time>` format at the same pace.

### Run it in the background (login agent)

```bash
macos/install.sh                     # build, install, start now and at every login
macos/install.sh --interval 2 --out ~/screen.txt   # same, with your own flags
macos/install.sh --uninstall
```

This copies the binary into `~/Applications/ASCII Screen.app`, signs it so macOS matches it by its identifier (`com.tetratorus.ascii-screen`) rather than by the exact binary, so the Screen Recording permission survives rebuilds, and registers a LaunchAgent. By default it writes `~/.ascii-screen/screen.txt`, keeps history in `~/.ascii-screen/history/` and logs to `~/Library/Logs/ascii-screen.log`. The first time, macOS lists "ASCII Screen" under System Settings > Privacy & Security > Screen Recording. Turn it on and the agent restarts itself within 30s. launchd also restarts it if capture stops (for example when a display is unplugged). Check it with `launchctl print gui/$(id -u)/com.tetratorus.ascii-screen`. If the log keeps saying the permission is missing even though the switch is on (for example after an install from an older version of this script), run `tccutil reset ScreenCapture com.tetratorus.ascii-screen` and turn it on again.

When run from a terminal, the terminal needs Screen Recording permission (System Settings > Privacy & Security). When stdout isn't a terminal, frames are separated by a form feed line. The Swift detector and renderer are ports of `detect_lines.js` and `ascii.js`; the test suite checks they produce identical output whenever the binary has been built.

## Python port (cross-platform)
`index.py` mirrors the CLI using RapidOCR by default, so it runs off macOS too. Requires Python 3.9+.

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python index.py path/to/img [--width 160] [--height 60] [--px 0.5 --py 0.5] [--ocr rapidocr|apple]
```

`./compare.sh path/to/img` runs the JS, Python + RapidOCR and Python + Apple Vision pipelines side by side (uses `python3` on `PATH`).

## Boundary detection

The JS and Python detectors find long horizontal/vertical colour transitions,
including boundaries between filled regions with no explicit border stroke.
Nearby edges are merged, and locally solid colours distinguish UI regions from
photo texture. The detector retains the four image borders.

This is a pixel heuristic, not semantic segmentation: rounded corners are
approximated by straight segments, and gradual shadows or translucent panels
can be missed. Large glyph stems, underlines and icons can still produce false
segments. Lossless screenshots work best; JPEG compression affects flat-colour
filtering.

Rendering suppresses segments contained in OCR text boxes (usually glyph stems
or underlines). A `_` draws a boundary along the bottom of its cell, so boxes
render as ` ____ ` over `|    |` over `|____|`: verticals start on the row below
the top edge, top corners stay blank, and `|` marks bottom corners and other
junctions. Line ends that grid quantisation leaves one cell apart are snapped
together, so corners meet instead of overhanging. Vertical
boundaries take precedence over colliding characters on the coarse ASCII grid;
horizontal rules underline text. Use a wider canvas for dense tables to reduce
text collisions. The renderer's `originalText` field retains text before the
boundary overlay.

Run the generated-image regressions (including JS/Python output parity):

```bash
npm ci
.venv/bin/python -m unittest discover -s tests -v
```

## Shell script to convert latest screenshot
```
tt () {
	local screenshots_dir=~/Desktop
	local sorted_files=$(ls -t $screenshots_dir)
	local selected_file=$(echo "$sorted_files" | sed "${1}q;d")
	if [ -n "$selected_file" ]
	then
		ascii-screenshot "$screenshots_dir/$selected_file" "${@:2}"
	else
		echo "No such file found at position $1." >&2
	fi
}
```

## Acknowledgments
Inspired by the work on the [Tarsier](https://github.com/tarsier-project) and [Textra](https://github.com/textra) GitHub projects.

---

## Example
```
 ______________________________________________________________________________________________________________________________________________________________ 
|                                                                                                                    ___________________________ |______||  |  |
|       Platform - Solutions - Resources - Open Source - Enterprise - Pricing                                       |Search             ||Sign i||Sign u||  |  |
|                                                                                                                   |___________________||______|________|  |  |
|________________________________________________________________________________________________________________________________________________________|__|__|
|                                                                                                                                                              |
| tetratorus / ascii-screenshot                                                                                                                                |
|                                                                                                                                                              |
|                                                                                                                                                              |
| ‹> Code • Issues  !. Pull requests • Actions # Projects • Security and quality ~ Insights                                                                    |
|______________________________________________________________________________________________________________________________________________________________|
|                                                                                                              _____________________________                   |
|                     ascii-screenshot Public                                                                 |A Notifica||ons & Fo|| 1 * St|r 2               |
|                                                                                                             |__________||________||_______|                  |
|                  __________________________________________________________________________________________________________________________                  |
|                   ___________                                               _______________________________                                                  |
|                  |           |                                             |                   ||          |                                                 |
|                  |g̲º̲_m̲a̲s̲t̲e̲r̲_-̲|  1 Branch • O Tags                          |Q̲_G̲o̲_t̲o̲_f̲i̲l̲e̲_______||<̲>̲_C̲o̲d̲e̲_-̲_|   About                                         |
|                   _________________________________________________________________________________________                                                  |
|                  |                                                                                         |   OCR plus line detection that renders          |
|                  |   tetratorus Preserve underscore alignment at boundary intersections 3d3b42a • 2 days ag| 47 Commits images as layout-aware ASCII text —  |
|                  |_________________________________________________________________________________________|                                                 |
|                  |                                                                                         |   a cheap way to give text-only LLMs            |
|                  |• public                            added back lines                            2 years a|o  visual context.                               |
|                  |_________________________________________________________________________________________|                                                 |
|                  |                                                                                         |   M Readme                                      |
|                  |_•̲_t̲e̲s̲t̲s̲____________________________P̲r̲e̲s̲e̲r̲v̲e̲_u̲n̲d̲e̲r̲s̲c̲o̲r̲e̲_a̲l̲i̲g̲n̲m̲e̲n̲t̲_a̲t̲_b̲o̲u̲n̲d̲a̲r̲y̲_i̲n̲t̲e̲r̲s̲e̲c̲t̲i̲o̲|s 2 days ago                                     |
|                  |                                                                                         |   1 Activity                                    |
|                  |•.gitignore                         Fix OCR JSON parsing and OpenCV 5 line detection 4 da|s ago                                            |
|                  |_________________________________________________________________________________________|   * 2 stars                                     |
|                  |                                                                                         |   • 1 watching                                  |
|                  |•̲_R̲E̲A̲D̲M̲E̲.̲m̲d̲_________________________P̲r̲e̲s̲e̲r̲v̲e̲_u̲n̲d̲e̲r̲s̲c̲o̲r̲e̲_a̲l̲i̲g̲n̲m̲e̲n̲t̲_a̲t̲_b̲o̲u̲n̲d̲a̲r̲y̲_i̲n̲t̲e̲r̲s̲e̲c̲t̲i̲o̲|s 2 days ago                                     |
|                  |                                                                                         |   & 1 fork                                      |
|                  |• ascii.js R                        Preserve underscore alignment at boundary intersectio|s 2 days ago                                     |
|                  |_________________________________________________________________________________________|   Report repository                             |
|                  |                                                                                         |   ____________________________                  |
|                  |•̲_a̲s̲c̲i̲i̲_̲s̲c̲r̲e̲e̲n̲s̲h̲o̲t̲.̲p̲y̲_______________P̲r̲e̲s̲e̲r̲v̲e̲_u̲n̲d̲e̲r̲s̲c̲o̲r̲e̲_a̲l̲i̲g̲n̲m̲e̲n̲t̲_a̲t̲_b̲o̲u̲n̲d̲a̲r̲y̲_i̲n̲t̲e̲r̲s̲e̲c̲t̲i̲o̲|s 2 days ago                                     |
|                  |                                                                                         |   Releases                                      |
|                  |• compare.sh                        Add cross-platform Python port with swappable OCR bac|.... 4 months ago                                |
|                  |_________________________________________________________________________________________|   No releases published                         |
|                  |                                                                                         |   ____________________________                  |
|                  |•̲_d̲e̲t̲e̲c̲t̲_̲l̲i̲n̲e̲s̲.̲j̲s̲___________________D̲e̲t̲e̲c̲t̲_f̲i̲l̲l̲e̲d̲_U̲l̲_b̲o̲u̲n̲d̲a̲r̲i̲e̲s̲_a̲n̲d̲_f̲i̲l̲t̲e̲r̲_t̲e̲x̲t̲u̲r̲e̲d̲_e̲d̲g̲e̲s̲|4 days ago                                       |
|                  |                                                                                         |                                                 |
|                  |• index.js                          Fix OCR JSON parsing and OpenCV 5 line detection 4 da|s ago Contributors 3                             |
|                  |_________________________________________________________________________________________|                                                 |
|                  |• index.py                          Add cross-platform Python port with swappable OCR bac|... 4 months ago tetratorus Leonard Tan          |
|                  |_________________________________________________________________________________________|                                                 |
|                  |                                                                                         |       devin-ai-integration[bot]                 |
|                  |•̲_l̲i̲n̲e̲s̲.̲j̲s̲o̲n̲________________________t̲u̲r̲n̲_i̲n̲t̲o̲_a̲_s̲i̲n̲g̲l̲e̲_c̲l̲i̲______________________2̲_y̲e̲a̲r̲s̲_a̲|o                                                |
|                  |                                                                                         |                                                 |
|                  |• ocr.scpt                          Revert "recognise chinese, bump version"      last ye|r      smolfroggo                                |
|                  |_________________________________________________________________________________________|   ____________________________                  |
|                  |                                                                                         |                                                 |
|                  |•̲_p̲a̲c̲k̲a̲g̲e̲-̲l̲o̲c̲k̲.̲j̲s̲o̲n̲_________________D̲e̲t̲e̲c̲t̲_f̲i̲l̲l̲e̲d̲_U̲l̲_b̲o̲u̲n̲d̲a̲r̲i̲e̲s̲_a̲n̲d̲_f̲i̲l̲t̲e̲r̲_t̲e̲x̲t̲u̲r̲e̲d̲_e̲d̲g̲e̲s̲|4 days ago                                       |
|                  |                                                                                         |   Languages                                     |
|                  |• package.json                      Detect filled Ul boundaries and filter textured edges|4 da̲y̲s̲_a̲g̲o̲_____________________                  |
|                  |_________________________________________________________________________________________|                                                 |
|                  |                                                                                         |   • Python 52.5% • JavaScript 30.9%             |
|                  |•̲_r̲e̲q̲u̲i̲r̲e̲m̲e̲n̲t̲s̲.̲t̲x̲t̲__________________F̲i̲x̲_O̲C̲R̲_J̲S̲O̲N̲_p̲a̲r̲s̲i̲n̲g̲_a̲n̲d̲_O̲p̲e̲n̲C̲V̲_5̲_l̲i̲n̲e̲_d̲e̲t̲e̲c̲t̲i̲o̲n̲_4̲_d̲a̲|s ago • HTML 14.5% • Shell 2.1%                  |
|__________________|_________________________________________________________________________________________|_________________________________________________|
```

**Note**: This project is experimental and may not work optimally for all image sizes or types. Feedback and contributions are welcome!
