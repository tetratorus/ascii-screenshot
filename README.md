# ASCII Screenshot

A simple tool to generate an ASCII-like version of images, optimized for screenshots. It also includes basic line detection to enhance the ASCII output.

## Features
- Converts images to ASCII-like art.
- Optimized for screenshots.
- Basic line detection for enhanced ASCII output.
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
________________________________________________________________________________________________________________________________________________________________
|                                                                                                                                                              |
| < > Code     Issues                      Actions                                                                                                             |
|                         Pull requests            # Projects  D Wiki       Security I Insights      Settings                                                  |
________________________________________________________________________________________________________________________________________________________________
|                                                                                             _______                                                          |
|                                                                                                                                                              |
|                                                                                                                                            Star              |
|         ascil-screenshot Public                                                            _&̲_P̲i̲n̲__  • Unwatch        2 Fork O                               |
|                                                                                                                                                              |
|      __________________________________________________________________________________________________________________________________________________      |
|                                                                                                                                                              |
|                                                            __________________________                                                                        |
|                                                                                                                                                              |
|       & master       § 1 Branch • O Tags                    • Go to file                Add file    <> Code ~      About                                     |
|      _____________________________________________________________________________________________                                                           |
|      __________________________________________________________________________________________________________ |                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          | No description, website, or topics         |
|      |                                                                                             D 18 Commits |                                            |
|      |    tetratorus Update README.md                                            aa77d0e • 3 weeks ago          | provided.                                  |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |     Readme                                 |
|      |    public                                 added back lines                                   3 weeks ago |                                            |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          | * Activity                                 |
|      |                                                                                                          |                                            |
|      |    •gitignore                             cleanup                                            3 weeks ago |                                            |
|      ____________________________________________________________________________________________________________  # 0 stars                                 |
|      |                                                                                                          |                                            |
|      |    README.md                              Update README.md                                   3 weeks ago |     1 watching                             |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |    O forks                                 |
|      |    ascii.js                               update to 60 for height to respect 1600x1200 divisibility 3 weeks ago                                       |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |                                            |
|      |    detect_lines.js                        turn into a single cli                             3 weeks ago |  Releases                                  |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |                                            |
|      |   index.js                                working tt                                         3 weeks ago | No releases published                      |
|      ____________________________________________________________________________________________________________  Create a new release                      |
|      |                                                                                                          |                                            |
|      |    lines.json                             turn into a single cli                             3 weeks ago |                                            |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |  Packages                                  |
|      |    ocr.scpt                               turn into a single cli                             3 weeks ago |                                            |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          | No packages published                      |
|      |    opencv.js                              working                                            3 weeks ago |  Publish your first package                |
|      ____________________________________________________________________________________________________________                                            |
|      |                                                                                                          |                                            |
|      |                                                                                                          |                                            |
|      |    package-lock.json                      added back lines                                   3 weeks ago |                                            |
____________________________________________________________________________________________________________________L̲a̲n̲g̲u̲a̲g̲e̲s̲___________________________________
```

**Note**: This project is experimental and may not work optimally for all image sizes or types. Feedback and contributions are welcome!
