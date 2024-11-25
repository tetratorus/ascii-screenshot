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
npm install ascii-screenshot
```

## Usage
Run the tool from the command line, specifying the path to your image:

```bash
ascii-screenshot path/to/img
```

## Requirements
- **macOS only**: This tool uses `osascript` for some functionalities.
- Ensure your image resolution is close to **1600x1000** for best results.

## Acknowledgments
Inspired by the work on the [Tarsier](https://github.com/tarsier-project) and [Textra](https://github.com/textra) GitHub projects.

---

**Note**: This project is experimental and may not work optimally for all image sizes or types. Feedback and contributions are welcome!
