const { spawn } = require('child_process');
const { detectLines } = require('./detect_lines');
const { ascii } = require('./ascii');

async function asciiScreenshot(path) {
  // spawn process to call osascript
  const p1 = new Promise(resolve => {
    const o = spawn('osascript', ['ocr.scpt', 'new.jpg'])

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

  const { originalText, linesText, finalText } = ascii(screenshotJSON, linesJSON);

  console.log(finalText);
}

asciiScreenshot('new.jpg');
