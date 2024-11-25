const { Canvas, createCanvas, Image, ImageData, loadImage } = require('canvas');
const { JSDOM } = require('jsdom');

const detectLines = async function(filePath) {
  installDOM();
  await loadOpenCV();

  const image = await loadImage(filePath);
  const src = cv.imread(image);
  const gray = new cv.Mat();
  cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY, 0);

  const edges = new cv.Mat();
  cv.Canny(gray, edges, 20, 200, 3);

  const lines = new cv.Mat();
  const higherThreshold = 800; // Threshold for HoughLinesP
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
      boundingBoxes.push({
        text: "|",
        origin: { x: avgX / imgWidth, y: Math.min(y1, y2) / imgHeight },
        size: { width: 0, height: Math.abs(y1 - y2) / imgHeight },
      });
    } else if (Math.abs(dy) < 5) {
      const avgY = Math.round((y1 + y2) / 2);
      boundingBoxes.push({
        text: "_",
        origin: { x: Math.min(x1, x2) / imgWidth, y: avgY / imgHeight },
        size: { width: Math.abs(x1 - x2) / imgWidth, height: 0 },
      });
    }
  }

  // Add edge lines
  boundingBoxes.push(
    { text: "|", origin: { x: 0, y: 0 }, size: { width: 0, height: 1 } },
    { text: "|", origin: { x: 1, y: 0 }, size: { width: 0, height: 1 } },
    { text: "_", origin: { x: 0, y: 0 }, size: { width: 1, height: 0 } },
    { text: "_", origin: { x: 0, y: 1 }, size: { width: 1, height: 0 } }
  );

  let verticalLines = boundingBoxes.filter((box) => box.text === "|");
  let horizontalLines = boundingBoxes.filter((box) => box.text === "_");

  const groupedVerticalLines = [];
  while (verticalLines.length > 0) {
    const line = verticalLines.shift();
    const group = [line];
    let i = 0;
    while (i < verticalLines.length) {
      const nextLine = verticalLines[i];
      if (Math.abs(line.origin.x - nextLine.origin.x) < 0.01) {
        group.push(nextLine);
        verticalLines.splice(i, 1);
      } else {
        i++;
      }
    }
    groupedVerticalLines.push(group);
  }

  const groupedHorizontalLines = [];
  while (horizontalLines.length > 0) {
    const line = horizontalLines.shift();
    const group = [line];
    let i = 0;
    while (i < horizontalLines.length) {
      const nextLine = horizontalLines[i];
      if (Math.abs(line.origin.y - nextLine.origin.y) < 0.01) {
        group.push(nextLine);
        horizontalLines.splice(i, 1);
      } else {
        i++;
      }
    }
    groupedHorizontalLines.push(group);
  }

  const longestVerticalLines = [];
  for (const group of groupedVerticalLines) {
    const x = group[0].origin.x;
    let minY = group[0].origin.y;
    let maxY = group[0].origin.y + group[0].size.height;
    for (const line of group) {
      minY = Math.min(minY, line.origin.y);
      maxY = Math.max(maxY, line.origin.y + line.size.height);
    }
    longestVerticalLines.push({
      text: "|",
      origin: { x: x, y: minY },
      size: { width: 0, height: maxY - minY },
    });
  }

  const longestHorizontalLines = [];
  for (const group of groupedHorizontalLines) {
    const y = group[0].origin.y;
    let minX = group[0].origin.x;
    let maxX = group[0].origin.x + group[0].size.width;
    for (const line of group) {
      minX = Math.min(minX, line.origin.x);
      maxX = Math.max(maxX, line.origin.x + line.size.width);
    }
    longestHorizontalLines.push({
      text: "_",
      origin: { x: minX, y: y },
      size: { width: maxX - minX, height: 0 },
    });
  }

  boundingBoxes = [...longestVerticalLines, ...longestHorizontalLines];

  for (const box of boundingBoxes) {
    const x1 = box.origin.x * imgWidth;
    const y1 = box.origin.y * imgHeight;
    const x2 = x1 + box.size.width * imgWidth;
    const y2 = y1 + box.size.height * imgHeight;
    cv.line(src, new cv.Point(x1, y1), new cv.Point(x2, y2), [255, 0, 0, 255], 2);
  }

  // console.log(JSON.stringify(boundingBoxes, null, 2));

  const canvas = createCanvas(imgWidth, imgHeight);
  cv.imshow(canvas, src);

  src.delete();
  gray.delete();
  edges.delete();
  lines.delete();

  return boundingBoxes;
}

function loadOpenCV() {
  return new Promise((resolve) => {
    global.Module = { onRuntimeInitialized: resolve };
    global.cv = require('./opencv.js');
  });
}

function installDOM() {
  const dom = new JSDOM();
  global.document = dom.window.document;
  global.Image = Image;
  global.HTMLCanvasElement = Canvas;
  global.ImageData = ImageData;
  global.HTMLImageElement = Image;
}


module.exports = {
  detectLines,
  installDOM,
  loadOpenCV,
}
