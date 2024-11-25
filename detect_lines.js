const { Canvas, createCanvas, Image, ImageData, loadImage } = require('canvas');
const { JSDOM } = require('jsdom');
const { writeFileSync, existsSync, mkdirSync } = require("fs");

// This is our program. This time we use JavaScript async / await and promises to handle asynchronicity.
(async () => {
  // before loading opencv.js we emulate a minimal HTML DOM. See the function declaration below.
  installDOM();

  await loadOpenCV();

  // using node-canvas, we an image file to an object compatible with HTML DOM Image and therefore with cv.imread()
  const image = await loadImage('./new.jpg');

  const src = cv.imread(image);
  const gray = new cv.Mat();
  cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY, 0);

  const edges = new cv.Mat();
  cv.Canny(gray, edges, 50, 150, 3);

  const lines = new cv.Mat();
  const higherThreshold = 700;
  cv.HoughLinesP(edges, lines, 1, Math.PI / 180, higherThreshold, 50, 10);

  let boundingBoxes = [];
  const imgWidth = src.cols;
  const imgHeight = src.rows;

  for (let i = 0; i < lines.rows; ++i) {
    const x1 = lines.data32S[i * 4];
    const y1 = lines.data32S[i * 4 + 1];
    const x2 = lines.data32S[i * 4 + 2];
    const y2 = lines.data32S[i * 4 + 3];

    const dx = x2 - x1;
    const dy = y2 - y1;

    if (Math.abs(dx) < 5) {
      const avgX = Math.round((x1 + x2) / 2);
      const newX1 = new cv.Point(avgX, y1);
      const newX2 = new cv.Point(avgX, y2);
      cv.line(src, newX1, newX2, [255, 0, 0, 255], 2);

      const x = avgX / imgWidth;
      const y = (imgHeight - Math.min(y1, y2)) / imgHeight;
      const height = Math.abs(y1 - y2) / imgHeight;
      boundingBoxes.push({ "text": "|", "origin": { "x": x, "y": y }, "size": { "width": 0, "height": height } });
    } else if (Math.abs(dy) < 5) {
      const avgY = Math.round((y1 + y2) / 2);
      const newY1 = new cv.Point(x1, avgY);
      const newY2 = new cv.Point(x2, avgY);
      cv.line(src, newY1, newY2, [255, 0, 0, 255], 2);

      const x = Math.min(x1, x2) / imgWidth;
      const y = (imgHeight - avgY) / imgHeight;
      const width = Math.abs(x1 - x2) / imgWidth;
      boundingBoxes.push({ "text": "_", "origin": { "x": x, "y": y }, "size": { "width": width, "height": 0 } });
    }
  }

  console.log(JSON.stringify(boundingBoxes));

  // Create an object compatible with HTMLCanvasElement
  const canvas = createCanvas(imgWidth, imgHeight);
  cv.imshow(canvas, src);
  // writeFileSync('output.jpg', canvas.toBuffer('image/jpeg'));

  src.delete();
  gray.delete();
  edges.delete();
  lines.delete();
})();

// Load opencv.js just like before but using Promise instead of callbacks:
function loadOpenCV() {
  return new Promise(resolve => {
    global.Module = {
      onRuntimeInitialized: resolve
    };
    global.cv = require('./opencv.js');
  });
}

// Using jsdom and node-canvas we define some global variables to emulate HTML DOM.
// Although a complete emulation can be archived, here we only define those globals used
// by cv.imread() and cv.imshow().
function installDOM() {
  const dom = new JSDOM();
  global.document = dom.window.document;

  // The rest enables DOM image and canvas and is provided by node-canvas
  global.Image = Image;
  global.HTMLCanvasElement = Canvas;
  global.ImageData = ImageData;
  global.HTMLImageElement = Image;
}
