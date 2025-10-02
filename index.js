#!/usr/bin/env node
const { spawn } = require('child_process');
const { detectLines } = require('./detect_lines');
const { ascii } = require('./ascii');
const p = require('path')

async function asciiScreenshot(path, normX, normY, canvasWidth, canvasHeight) {
  // spawn process to call osascript
  const p1 = new Promise(resolve => {
    const scriptPath = p.resolve(__dirname, 'ocr.scpt');
    const o = spawn('osascript', [scriptPath, path])

    // pipe stdout and stderr to a string
    let output = '';
    o.stdout.on('data', (data) => {
      output += data;
    });
    o.stderr.on('data', (data) => {
      output += data;
    });

    // log output when process exits
    o.on('exit', () => {
      resolve(JSON.parse(output));
    });
  })

  const p2 = detectLines(path);

  const [screenshotJSON, linesJSON] = await Promise.all([p1, p2]);

  // console.log(screenshotJSON);
  // console.log(linesJSON);

  const { finalText } = ascii(screenshotJSON, linesJSON, normX, normY, canvasWidth, canvasHeight);

  console.log(finalText);
}

function parseFlags(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const val = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
      flags[key] = isNaN(val) ? val : Number(val);
    } else {
      positional.push(arg);
    }
  }
  return { flags, positional };
}

const { flags, positional } = parseFlags(process.argv.slice(2));

if (flags.h || flags.help) {
  console.log(`
Usage: ascii-screenshot <image> [options]

Description:
  Takes a screenshot image, runs OCR + line detection, and renders
  the result as ASCII art. Optionally overlays a pointer (👆)
  at a normalized coordinate (0,0 top-left, 1,1 bottom-right)

Positional arguments:
  <image>              Path to the image file

Options:
  --px <float>         Normalized X coordinate (0–1) for pointer
  --py <float>         Normalized Y coordinate (0–1) for pointer
  --width <int>        Canvas width (default: 160)
  --height <int>       Canvas height (default: 60)
  -h, --help           Show this help message
`);
  process.exit(0);
}

const path = positional[0];
const px = flags.px ?? null;      // normalized X (0–1), just named px
const py = flags.py ?? null;      // normalized Y (0–1), just named py
const canvasWidth = flags.width || 160;
const canvasHeight = flags.height || 60;

if (!path) {
  console.error("Usage: ascii-screenshot <image> --px <0-1> --py <0-1> --width <n> --height <n>");
  process.exit(1);
}

asciiScreenshot(path, px, py, canvasWidth, canvasHeight).catch(err => {
  console.error("Error:", err.message);
  process.exit(1);
});
