const { JSDOM } = require('jsdom');
const { Canvas, Image, ImageData } = require('canvas');
const fs = require('fs');

// Setup DOM environment
function installDOM() {
  const dom = new JSDOM();
  global.document = dom.window.document;
  global.Image = Image;
  global.HTMLCanvasElement = Canvas;
  global.ImageData = ImageData;
  global.HTMLImageElement = Image;
}

// Initialize OpenCV
function loadOpenCV() {
  return new Promise(resolve => {
    global.Module = {
      onRuntimeInitialized: resolve
    };
    global.cv = require('./opencv.js');
  });
}

async function detectLines(imgElement) {
  let src = cv.imread(imgElement);
  let gray = new cv.Mat();
  cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY, 0);

  let edges = new cv.Mat();
  cv.Canny(gray, edges, 20, 200, 3);

  let lines = new cv.Mat();
  let higherThreshold = 800;
  cv.HoughLinesP(edges, lines, 1, Math.PI / 180, higherThreshold, 50, 10);

  let boundingBoxes = [];
  let imgWidth = src.cols;
  let imgHeight = src.rows;

  for (let i = 0; i < lines.rows; ++i) {
    let x1 = lines.data32S[i * 4];
    let y1 = lines.data32S[i * 4 + 1];
    let x2 = lines.data32S[i * 4 + 2];
    let y2 = lines.data32S[i * 4 + 3];

    let dx = x2 - x1;
    let dy = y2 - y1;

    if (Math.abs(dx) < 5) {
      x1 = x2 = Math.round((x1 + x2) / 2);
      let x = x1 / imgWidth;
      let y = Math.min(y1, y2) / imgHeight;
      let height = Math.abs(y1 - y2) / imgHeight;
      boundingBoxes.push({"text": "|", "origin": {"x": x, "y": y}, "size": {"width": 0, "height": height}});
    } else if (Math.abs(dy) < 5) {
      y1 = y2 = Math.round((y1 + y2) / 2);
      let x = Math.min(x1, x2) / imgWidth;
      let y = y1 / imgHeight;
      let width = Math.abs(x1 - x2) / imgWidth;
      boundingBoxes.push({"text": "_", "origin": {"x": x, "y": y}, "size": {"width": width, "height": 0}});
    }
  }

  // Add border lines
  boundingBoxes.push({"text": "|", "origin": {"x": 0, "y": 0}, "size": {"width": 0, "height": 1}});
  boundingBoxes.push({"text": "|", "origin": {"x": 1, "y": 0}, "size": {"width": 0, "height": 1}});
  boundingBoxes.push({"text": "_", "origin": {"x": 0, "y": 0}, "size": {"width": 1, "height": 0}});
  boundingBoxes.push({"text": "_", "origin": {"x": 0, "y": 1}, "size": {"width": 1, "height": 0}});

  src.delete();
  gray.delete();
  edges.delete();
  lines.delete();

  return boundingBoxes;
}

async function main() {
  try {
    installDOM();
    await loadOpenCV();

    // Load the image
    const img = new Image();
    const imgData = fs.readFileSync('./new.jpg');
    img.src = Buffer.from(imgData);

    // Process the image
    const boundingBoxes = await detectLines(img);
    
    // Output results
    console.log(JSON.stringify(boundingBoxes, null, 2));
  } catch (error) {
    console.error('Error processing image:', error);
  }
}

main();
