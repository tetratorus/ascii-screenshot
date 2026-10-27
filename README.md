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
