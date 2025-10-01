#!/usr/bin/env node
const { spawn } = require('child_process');
const { detectLines } = require('./detect_lines');
const { ascii } = require('./ascii');
const p = require('path')

async function asciiScreenshot(path) {
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

  const { finalText } = ascii(screenshotJSON, linesJSON);

  console.log(finalText);
}

const path = process.argv[2];
const normX = process.argv[3] ? parseFloat(process.argv[3]) : null;
const normY = process.argv[4] ? parseFloat(process.argv[4]) : null;

if (!path) {
  console.error('Usage: ascii-screenshot <path-to-image>');
  process.exit(1);
}

asciiScreenshot(path, normX, normY).catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
