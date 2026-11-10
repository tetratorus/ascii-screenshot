# ASCII Screen

A macOS background service that keeps a text copy of your screen, about once a second. Text is placed where it sits on screen, and UI boxes, rules and table cells are drawn as `_` and `|`. It keeps a compressed, searchable history that you can replay in the terminal. The point is to give AI agents and other text tools a cheap view of what's on your screen, using as little battery as possible. Needs macOS 14 or later.

## Everything stays on your Mac

- Capture uses Apple's ScreenCaptureKit, and text is read by Apple Vision, which runs on the Mac itself.
- There is no network code: nothing is uploaded, and there is no account or telemetry.
- The output and history live in `~/.ascii-screen/`, readable only by your user account.
- It records **everything** on screen, including private windows and any password shown in plain text. There is no list of apps to skip. When that matters, pause it:
  ```bash
  launchctl bootout gui/$(id -u)/com.tetratorus.ascii-screen                                      # pause (starts again at next login)
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tetratorus.ascii-screen.plist       # resume
  ```

## Quick start

1. Install the Xcode command line tools if you don't have `swift`: `xcode-select --install`.
2. Build and install. This starts it now and at every login, and puts `ascii-screen` on your PATH:
   ```bash
   git clone https://github.com/tetratorus/ascii-screenshot && cd ascii-screenshot
   macos/install.sh
   ```
3. In System Settings > Privacy & Security > Screen Recording, turn on **ASCII Screen**. It starts capturing within 30 seconds. If it isn't listed, click + and pick `~/Library/Application Support/ASCII Screen/ASCII Screen` (press Cmd-Shift-G to type the path).
4. Check it: `cat ~/.ascii-screen/screen.txt`. If the installer said it added `~/.local/bin` to your PATH, open a new terminal first.
5. Replay the last few minutes: `ascii-screen --play --from 5m`.

While it records, macOS shows a small purple dot next to Control Center. That's macOS, and it can't be turned off.

## Use

```bash
cat ~/.ascii-screen/screen.txt                 # the screen right now
ascii-screen --search "invoice"                # when "invoice" was on screen, newest first
ascii-screen --search 'invoice OR receipt' --from 7d --json
ascii-screen --at 14:05                        # what was on screen at 14:05 today
ascii-screen --at 5m --width 400 --height 150  # 5 minutes ago, on a bigger grid
ascii-screen --play --from 1m --speed 1        # replay the last minute in real time
ascii-screen --play --from 14:00               # replay from 14:00 at 10x
ascii-screen --delete --from 14:05 --to 14:20  # remove 14:05-14:20 as if the screen had stood still
```

- **The live file** `~/.ascii-screen/screen.txt` is replaced in one step on every change, so a reader never sees half a frame. It is drawn 240 columns wide, with as many rows as keep the screen's shape (at most 100).
- **Times** for `--at`, `--from` and `--to` can be how long ago (`30s`, `5m`, `1h30m`, `2d`), `HH:MM[:SS]` today, `now`, or a full ISO 8601 time.
- **`--at` and `--play`** draw saved frames to fit your terminal, or at `--width`/`--height` if you give them.

Keys while `--play` runs:

| Key | Does |
| --- | --- |
| space | pause / resume |
| left / right | step one frame back / forward (pauses) |
| up / down | double / halve the speed |
| `=` / `-` | redraw at a higher / lower resolution (25% more or fewer columns and rows per press) |
| q | quit |

## Change settings, update, uninstall

Any flags you give `install.sh` are passed to the service. It always keeps the live file (`--out ~/.ascii-screen/screen.txt`) and history (`--history ~/.ascii-screen/history`) on, unless you give your own `--out` or `--history`.

```bash
macos/install.sh --auto-language                                     # e.g. turn on other languages
plutil -p ~/Library/LaunchAgents/com.tetratorus.ascii-screen.plist   # flags it runs with now
git pull && macos/install.sh <same flags>                            # update; the Screen Recording permission is kept
macos/install.sh --uninstall                                         # stop and remove; history and log are kept
rm -rf ~/.ascii-screen ~/Library/Logs/ascii-screen.log               # also delete the history and log
```

After uninstalling, you can also remove the `ASCII Screen` entry from the Screen Recording list with the − button.

Useful flags (`ascii-screen --help` lists them all):

| Flag | Default | What it does |
| --- | --- | --- |
| `--auto-language` | off (English only) | Reads Chinese, Japanese, Korean, Thai, Russian, Arabic and others, including lines mixed with English. About 15% more CPU on English screens and about double on dense Chinese or Thai, plus about 90 MB more memory. |
| `--width` / `--height` | 240 / keeps the screen's shape (at most 100) | Grid size of the live file. History keeps every text box, so this doesn't limit what's saved. |
| `--interval <s>` | 1 | Minimum seconds between frames. |
| `--keep-days <n>` | 365 | Delete history older than this (0 keeps everything). |
| `--display <i>` | 0 (main display) | Which display to capture. |
| `--no-cursor` | pointer shown | Don't draw the 👆 pointer. |
| `--stats` | off | Log time and CPU per frame to the log. |

## What it costs

Measured on an M4 virtual machine (1600x1200), which has no Neural Engine, so text reading runs on the CPU. A real Mac is likely cheaper, but this hasn't been measured.

| Screen | CPU per refresh |
| --- | --- |
| Nothing changed | ~0 (no frame delivered) |
| Small change (clock, typing) | ~0.1–0.3s |
| Scrolling while reading | ~0.9s |
| Whole screen changed | ~0.75s |

- **Memory:** about 180 MB just after starting, peaking around 380 MB during busy browsing.
- **Disk:** about 800 bytes per changed frame. A year at 8 hours a day comes to roughly 4–12 GB (an estimate), plus about a third of that for the search index. Check with `du -sh ~/.ascii-screen/history`.
- **Battery:** it runs as a low-priority background process (efficiency cores, throttled disk access) and stops while the screen is locked or asleep. Its energy shows under "ASCII Screen" in Activity Monitor.

## Limitations

- English only unless you turn on `--auto-language`. Even with it on, one read handles one writing system, so a screen with both Chinese and Thai gets only one of them right.
- Text reading makes mistakes, e.g. similar-looking Chinese characters (`考研` read as `考砑`), or icons read as letters. Search has no fuzzy matching (see [AGENTS.md](AGENTS.md#screen-history-index) for working around misreads).
- The grid can't fit everything. Text that runs into a box edge is cut with `…` and keeps its last few characters. Use a bigger `--width`, or `=` during `--play`.
- Box lines come from pixel edges: rounded corners become straight lines, and soft shadows or see-through panels can be missed.
- It captures one display.
- It doesn't record while the screen is locked or asleep.

## Troubleshooting

- **`screen.txt` isn't updating:** check that it's running with `launchctl print gui/$(id -u)/com.tetratorus.ascii-screen | grep state`, and read `tail ~/Library/Logs/ascii-screen.log`.
- **The log says the permission is missing, but the switch is on:** remove the `ASCII Screen` entry with the − button, run the installer again and turn the new entry on. This can happen after upgrading from an older version.
- **`ascii-screen: command not found`:** open a new terminal. The installer may have added `~/.local/bin` to your PATH in `~/.zshrc`.
- **Chinese, Thai and similar text comes out as junk:** reinstall with `--auto-language` (see above).
- **`--search`, `--at` or `--play` find nothing:** history is saved only with `--history`. Frames reach disk within 10 seconds.

## Using it with AI agents

- `~/.ascii-screen/screen.txt` is always the current screen, ready to paste into a prompt or read from a tool.
- `ascii-screen --search <query> --json` returns one JSON object per match. Pass its `start` time to `--at` to see the full screen.
- [AGENTS.md](AGENTS.md#screen-history-index) describes the history files and how to query the SQLite index directly.

## Example

A Wikipedia page in Chrome, from `ascii-screen --at now --width 150 --height 45`:

```
|____________________________________________________________________________________________________________________________________________________|
|•̲〇̲〇̲<̲_W̲_S̲in̲g̲a̲p̲o̲r̲e̲_-̲_W̲i̲k̲i̲p̲e̲d̲i̲a̲___+̲_________________________________________________________________________________     App Background Activity     |
|< > C en.wikipedia.org/wiki/Singapore                                                                                   "ASCII Screen" can run…ound.|
|________________________________________________________________________________________________________________________I̲t̲e̲m̲s̲_&̲_E̲x̲t̲e̲n̲s̲i̲o̲n̲s̲.̲_Y̲o̲…̲L̲o̲g̲in|
|                                                         Google Chrome isn't your def̲a̲u̲l̲t̲_b̲r̲o̲wser Set as default       __________________________   |
|_______________________r̲u̲v̲u̲_n̲y̲_r̲o̲n̲g̲n̲w̲u̲w̲_n̲u̲m̲n̲u̲n̲y̲_m̲u̲_v̲u̲n̲u̲_______________________________________________________________| Chrome didn't shut dow…ctly.|
|                       Bugis. 42) However, the Sultanate was weakened by factional…, the||                     ||     |                             |
|    C̲o̲n̲t̲e̲n̲t̲s̲_h̲i̲d̲e̲___   Temenggong of Johor to Tengku Abdul Rahman, as well as his …o the||                     ||   Ap|   Help make Google Chr…er by|
|    (Top)              Sultan's elder brother Tengku Long, who was living in exile…ands.||                     ||   Te|   to Google sending cr…stics|
|    Name and etymology With the Temenggong's help, Raffles managed to smuggle Teng…pore.||_____________________||     |                     ______  |
|   > History           Raffles offered to recognise Tengku Long as the rightful Su…le of|Letter from Willi…ar to|凸   |                     Restore |
|   > Geography         Sultan Hussein, as well as provide him with a yearly paymen…00 to|Sultan Muhammad K…, the|     |                     ______  |
|   > Government and politics the Temenggong; in return, Sultan Hussein would grant…ish a|21st Sultan of Br…line,|   La|_____________________________|
|   › Economy           trading post on Singapore. 43) The Treaty of Singapore was …4445]|Farquhar mentions…ssein|   Width                           |
|   > Demographics                                                                       |Shah and Temenggo…ahman|   ________________                |
|   › Culture           In 1824, a further treaty with the Sultan led to the entire…itish|to establish a fa…mpany|     Standard                      |
|    See also            Empire.(46] In 1826, Singapore became part of the Straits …r the|F̲e̲b̲r̲u̲a̲r̲y̲_1̲8̲1̲9̲/̲3̲9̲)̲(̲4̲0̲)̲__|   Wide                            |
|                       jurisdiction of British India. Singapore became the regional capital in 1836.47] Prior to Raffles'                           |
|    Notes              arrival, there were only about a thousand people living on the island, mostly indigenous     C̲o̲l̲o̲r̲___________                |
|   › References        Malays along with a handful of Chinese. 48] By 1860 the population had swelled to over 80,000, more than half being Chi… (46]|
|    Works cited        Many of these early immigrants came to work on the pepper and gambier plantations. 49) In 1867, the Straits Settlements were |
|    Further reading    separated from British India, coming under the direct control of Britain. (50] Later, in the 1890s, when the rubber ind…ecame|
|    External links     established in Malaya and Singapore, 51] the island became a global centre for rubber sorting and export.(46]                |
|                       Singapore was not greatly affected by the First World War (1914-191̲8̲)̲,̲_a̲s̲_t̲h̲e̲_c̲o̲n̲f̲l̲i̲c̲t̲_d̲i̲d not                               |
|                       spread to Southeast Asia. The only significant event during…apore|                       |                                   |
|                       Mutiny by Muslim sepoys from British India, who were garris…After|                       |                                   |
|                       hearing rumours that they were to be sent to fight the Otto…, the||                      |                                   |
|                       soldiers rebelled, killing their officers and several Briti…y was||                      |                                   |
|                       suppressed by non-Muslim troops arriving from Johore and Bu….(53]||                      |                                   |
|                                                                                        ||______________________|                                   |
|                       After World War I, the British built the large Singapore Na…nsive|A lithograph by V…ks of|凸                                 |
|                       at a slow pace until the Japanese invasion of Manchuria in …eeded|Singapore City in…llich|                                   |
|                       fully completed in 1938, it was nonetheless the largest dry…rgest|_______________________|                                   |
|                       floating dock, and had enough fuel tanks to support the entire Brit̲i̲s̲h̲_n̲a̲v̲y̲_f̲o̲r̲_s̲i̲x̲_m̲o̲n̲t̲h̲s. 4)                               |
|                       [55)(56) The base was defended by heavy 15-inch (380 mm) na… Fort|                       |                                   |
|                       Siloso, Fort Canning and Labrador, as well as a Royal Air F…Base.|                       |                                   |
|                       Winston Churchill touted it as the "Gibraltar of the East",…often|                       |                                   |
|                       referred to the base as simply "East of Suez". However, the…ioned|                       |                                   |
|                       in Europe, and the British could not afford to build a seco…ts in|                       |                                   |
|                       Asia. The plan was for the Home Fleet to sail quickly to Si…of an|_______________________|                                   |
|                       emergency. After World War Il broke out in 1939, the fleet …nding|Battlecruiser HMS…of 凸|                                   |
|________________________________________________________________________________________|h̲e̲_f̲e̲w̲_c̲a̲p̲i̲t̲a̲l̲_s̲h̲…̲c̲h̲i̲l̲l̲|___________________________________|
|                                                                        ctv                              _____                                      |
|____________________________________________________________________________________________________________________________________________________|
```

## Run it by hand (without the background service)

```bash
ascii-screen                         # live view in the terminal
ascii-screen --out /tmp/screen.txt   # atomically rewrite a file on each change
ascii-screen --once                  # one capture
ascii-screen --image shot.png        # convert an image file
ascii-screen --stats                 # per-frame timing/CPU on stderr
ascii-screen --history ~/screen-history   # also keep every changed frame, compressed
ascii-screen --help                  # all options
```

When run from a terminal, the terminal needs Screen Recording permission, and the energy is charged to the terminal instead of "ASCII Screen". When stdout isn't a terminal, frames are separated by a form feed line. To build without installing: `cd macos && swift build -c release` (binary at `macos/.build/release/ascii-screen`).

## How history and search work

With `--history <dir>`, every frame that differs from the previous one is kept in `<dir>/YYYY-MM-DD.txt.gz`. Each record is a `@@ <ISO 8601 time>` line followed by everything the text reader found on that frame, before it was fitted onto a grid: each piece of text with its position, each box line, and the pointer (format in [Frame.swift](macos/Sources/ascii-screen/Frame.swift)). So `--at` and `--play` can draw a saved frame at any `--width`/`--height`, and search sees text that didn't fit the grid. gzip shrinks it to about 800 bytes per frame while scrolling (measured on the VM; about 20% more than the same frames drawn at 240 columns). Records from older versions hold the drawn frame and are shown as saved. Frames are held in memory for at most 10 seconds and then written as one batch, and also when the screen sleeps or locks or the process stops. A crash loses at most the last 10 seconds, and the disk isn't touched on every change. Files older than `--keep-days` (default 365; roughly 4–12 GB a year at 8 hours a day, up to about 36 GB if the screen changes every second around the clock (estimates)) are deleted. Read history with `gzcat <dir>/2026-10-27.txt.gz | less`, or print the frame shown at a given time with `--at` (drawn to fit your terminal, or at `--width`/`--height`, e.g. `--width 400 --height 150`). Times can be how long ago (`30s`, `5m`, `1h30m`, `2d`), `HH:MM[:SS]` today, `now`, or a full ISO 8601 time.

`--play` replays saved history in the terminal like a screen recording. `--from` and `--to` take the same time formats (default: midnight today to now). Frames are shown at their recorded spacing sped up by `--speed` (default 10x), and idle stretches are capped at `--max-gap` seconds (default 2). Keys are listed under [Use](#use); anything past the window is cropped. Frames start out drawn to fit the terminal window, or at `--width`/`--height` if given. When stdout isn't a terminal it prints the records in `@@ <time>` format at the same pace. Frames are read from disk as playback reaches them, so memory stays flat even for a year-long range (left steps back up to 1,000 frames).

`--search <query>` lists when matching text was on screen, newest first, as runs of consecutive frames with the best-matching line (`--from`/`--to` narrow the range, `--limit` sets how many runs, default 20, `--json` prints one JSON object per run). Plain words match in any order anywhere on the screen, and each also matches longer words it starts (`invoice` finds `invoices`). The query is also [SQLite FTS5 syntax](https://sqlite.org/fts5.html#full_text_query_syntax): `invo*`, `invoice OR receipt`, `invoice NOT paid`, `"exact phrase"`. Case, spacing and box lines don't matter. It uses `<dir>/index.sqlite`, an SQLite full-text index of every saved frame: words only, no word positions and no copy of the text, about a third of the history's size on real screens. So `NEAR` isn't available, and a quoted phrase is found by its words and then checked against the frame text (inside an `OR` query only the words are required). The index is updated with each history write and rebuilt from the day files if missing, behind, or from an older version, so it's safe to delete. `--at` and `--play` also use it to jump straight to the right place in a day file. See [AGENTS.md](AGENTS.md#screen-history-index) for querying it directly.

`--delete --from <time> --to <time>` removes every frame saved in that range (both are required; `--to` is capped at now). Only changed frames are ever saved, so a stretch with no frames is exactly what a still screen looks like: afterwards `--at`, `--play` and `--search` show the frame from just before the range staying up until the first frame after it, with no gap, marker or blank frame. Parts of the day file outside the range are kept byte for byte; the rest is recompressed without the removed frames and swapped in atomically, and the index is rebuilt for that day and compacted, so the removed words aren't left in `index.sqlite` or its write-ahead log either. If the range reaches into the last few seconds, it first waits up to 13 seconds so the running service has saved them. The frame shown during the range was on screen before it, so to hide something that appeared at 14:05:30, start the range at or before 14:05:30. Copies made outside `~/.ascii-screen` (Time Machine backups, APFS snapshots) and freed disk blocks aren't touched.

## How it keeps CPU low

- **Change-driven.** ScreenCaptureKit only hands over a frame when something on screen changed, so a static screen costs ~0 CPU. Frames that are pixel-identical to the last one are dropped after a `memcmp`.
- **Incremental OCR.** Changed 32px tiles are grouped into regions, grown so no cached word straddles an edge, and only those regions are re-OCRed (Vision `regionOfInterest`); the rest of the text is reused. A full OCR runs when over half the screen changed, and every 30 incremental frames (`--full-every`).
- **Scrolling reuses text.** When a change looks like a vertical scroll (rows of the old frame reappear shifted), the cached text moves with the page and only newly revealed rows, plus anything that changed on top of the scroll, are read. Every frame is still read; on the VM, reading-speed scrolling of a Wikipedia article went from ~1.5s to ~0.9s CPU per frame. Page-sized jumps reveal mostly new text, so they cost about the same as before.
- **One Vision call per frame.** Each Vision call has a large fixed cost (~50–70ms CPU even on a tiny crop), so when several separate regions change they are copied into one packed image and read in a single call (`--no-atlas` to disable). Benchmarks: `macos/benchmarks/OCR.md`.
- **English only by default, with Vision's previous text model.** It read the same text from busy browser screens as the newest model and keeps ~90MB less working memory resident (busy-browsing peak on the VM: 560MB before, 376MB after). `--auto-language` makes Vision detect the language of each read instead (newest model): it reads Chinese, Japanese, Korean, Thai and others, including lines that mix them with English, which English-only mode turns into junk. On the VM a dense Chinese+English or Thai+English screen took about twice the CPU to read with it (0.6s vs 1.1–1.2s); plain English screens cost about the same, and a busy English browsing run ~15% more. To turn it on for the background service: `macos/install.sh --auto-language`.
- **No language correction by default.** On UI text it barely changes the output and costs ~2x the CPU (`--correction` turns it back on). `--fast` is cheaper still but much worse on small UI text.
- **In-process, in memory.** Capture, line detection and rendering run in one process on the captured buffer: no `screencapture`/`osascript`/node per frame, and no PNG encode/decode.
- **Low priority.** The process runs as a Darwin background process (efficiency cores, throttled I/O), and capture stops while the screen is locked or asleep.
- **Cheap cursor.** The pointer is left out of captured frames so moving it doesn't trigger a capture; its position is polled once per interval and only re-renders text (no OCR).

## Boundary detection

The detector finds long horizontal/vertical colour transitions,
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

## Development

```bash
swift build -c release --package-path macos
swift test -c release --package-path macos
```

See [AGENTS.md](AGENTS.md) for the full checks, benchmark rules and the history index schema.

## Acknowledgments
Inspired by the work on the [Tarsier](https://github.com/tarsier-project) and [Textra](https://github.com/textra) GitHub projects.

**Note**: This project is experimental. Feedback and contributions are welcome!
