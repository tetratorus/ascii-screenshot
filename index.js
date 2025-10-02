#!/usr/bin/env node
const { spawn } = require('child_process');
const { detectLines } = require('./detect_lines');
const { ascii } = require('./ascii');
const pathLib = require('path');

async function asciiScreenshot(path, normX, normY, canvasWidth, canvasHeight) {
  const p1 = new Promise(resolve => {
    const scriptPath = pathLib.resolve(__dirname, 'ocr.scpt');
    const o = spawn('osascript', [scriptPath, path]);

    let output = '';
    o.stdout.on('data', (data) => { output += data; });
    o.stderr.on('data', (data) => { output += data; });

    o.on('exit', () => {
      resolve(JSON.parse(output));
    });
  });

  const p2 = detectLines(path);
  const [screenshotJSON, linesJSON] = await Promise.all([p1, p2]);

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
      const val = argv[i + 1] && !argv[i + 1].startsWith("-") ? argv[++i] : true;
      flags[key] = /^\d+(\.\d+)?$/.test(val) ? Number(val) : val;
    } else if (arg.startsWith("-")) {
      // short flags like -h
      arg.slice(1).split("").forEach(c => flags[c] = true);
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

Options:
  --px <float>         Normalized X coordinate (0–1) for pointer
  --py <float>         Normalized Y coordinate (0–1) for pointer
  --width <int>        Canvas width (default: 160)
  --height <int>       Canvas height (default: 60)
  -h, --help           Show this help message
`);
  process.exit(0);
}

const imagePath = positional[0];
const px = flags.px ?? null;
const py = flags.py ?? null;
const canvasWidth = flags.width || 160;
const canvasHeight = flags.height || 60;

if (!imagePath) {
  console.error("Usage: ascii-screenshot <image> --px <0-1> --py <0-1> --width <n> --height <n>");
  process.exit(1);
}

asciiScreenshot(imagePath, px, py, canvasWidth, canvasHeight).catch(err => {
  console.error("Error:", err.message);
  process.exit(1);
});
