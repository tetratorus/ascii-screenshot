class CannyEdgeDetector {
  constructor(lowThresh, highThresh, apertureSize = 3, L2gradient = false) {
      this.lowThresh = lowThresh;
      this.highThresh = highThresh;
      this.apertureSize = apertureSize;
      this.L2gradient = L2gradient;
      this.gaussianKernel = this.createGaussianKernel(apertureSize);
  }

  createGaussianKernel(size, sigma = 1.4) {
      const kernel = [];
      const half = Math.floor(size / 2);
      let sum = 0;

      for (let i = -half; i <= half; i++) {
          kernel[i + half] = [];
          for (let j = -half; j <= half; j++) {
              const value = (1 / (2 * Math.PI * sigma * sigma)) * Math.exp(-(i * i + j * j) / (2 * sigma * sigma));
              kernel[i + half][j + half] = value;
              sum += value;
          }
      }

      // Normalize the kernel
      for (let i = 0; i < size; i++) {
          for (let j = 0; j < size; j++) {
              kernel[i][j] /= sum;
          }
      }

      return kernel;
  }

  applyKernel(image, kernel) {
      const width = image.width;
      const height = image.height;
      const half = Math.floor(kernel.length / 2);
      const output = new Float32Array(width * height);

      for (let y = 0; y < height; y++) {
          for (let x = 0; x < width; x++) {
              let sum = 0;
              for (let ky = -half; ky <= half; ky++) {
                  for (let kx = -half; kx <= half; kx++) {
                      const iy = y + ky;
                      const ix = x + kx;
                      if (iy >= 0 && iy < height && ix >= 0 && ix < width) {
                          sum += image.data[iy * width + ix] * kernel[ky + half][kx + half];
                      }
                  }
              }
              output[y * width + x] = sum;
          }
      }

      return output;
  }

  sobelOperator(image) {
      const width = image.width;
      const height = image.height;
      const Gx = new Float32Array(width * height);
      const Gy = new Float32Array(width * height);

      const sobelX = [
          [-1, 0, 1],
          [-2, 0, 2],
          [-1, 0, 1]
      ];

      const sobelY = [
          [-1, -2, -1],
          [0, 0, 0],
          [1, 2, 1]
      ];

      for (let y = 1; y < height - 1; y++) {
          for (let x = 1; x < width - 1; x++) {
              let sumX = 0;
              let sumY = 0;

              for (let ky = -1; ky <= 1; ky++) {
                  for (let kx = -1; kx <= 1; kx++) {
                      const pixel = image.data[(y + ky) * width + (x + kx)];
                      sumX += pixel * sobelX[ky + 1][kx + 1];
                      sumY += pixel * sobelY[ky + 1][kx + 1];
                  }
              }

              Gx[y * width + x] = sumX;
              Gy[y * width + x] = sumY;
          }
      }

      return { Gx, Gy };
  }

  gradientMagnitudeAndDirection(Gx, Gy, width, height) {
      const magnitude = new Float32Array(width * height);
      const direction = new Float32Array(width * height);

      for (let i = 0; i < width * height; i++) {
          magnitude[i] = Math.sqrt(Gx[i] * Gx[i] + Gy[i] * Gy[i]);
          direction[i] = Math.atan2(Gy[i], Gx[i]) * (180 / Math.PI);
      }

      return { magnitude, direction };
  }

  nonMaximumSuppression(magnitude, direction, width, height) {
      const output = new Float32Array(width * height);

      for (let y = 1; y < height - 1; y++) {
          for (let x = 1; x < width - 1; x++) {
              const angle = direction[y * width + x];
              const mag = magnitude[y * width + x];

              let neighbor1 = 0;
              let neighbor2 = 0;

              if ((angle >= -22.5 && angle <= 22.5) || (angle >= 157.5 || angle <= -157.5)) {
                  neighbor1 = magnitude[y * width + (x - 1)];
                  neighbor2 = magnitude[y * width + (x + 1)];
              } else if ((angle > 22.5 && angle <= 67.5) || (angle > -157.5 && angle <= -112.5)) {
                  neighbor1 = magnitude[(y - 1) * width + (x + 1)];
                  neighbor2 = magnitude[(y + 1) * width + (x - 1)];
              } else if ((angle > 67.5 && angle <= 112.5) || (angle > -112.5 && angle <= -67.5)) {
                  neighbor1 = magnitude[(y - 1) * width + x];
                  neighbor2 = magnitude[(y + 1) * width + x];
              } else if ((angle > 112.5 && angle <= 157.5) || (angle > -67.5 && angle <= -22.5)) {
                  neighbor1 = magnitude[(y - 1) * width + (x - 1)];
                  neighbor2 = magnitude[(y + 1) * width + (x + 1)];
              }

              if (mag >= neighbor1 && mag >= neighbor2) {
                  output[y * width + x] = mag;
              } else {
                  output[y * width + x] = 0;
              }
          }
      }

      return output;
  }

  doubleThresholding(image) {
      const width = image.width;
      const height = image.height;
      const output = new Uint8Array(width * height);

      for (let i = 0; i < width * height; i++) {
          const pixel = image[i];
          if (pixel >= this.highThresh) {
              output[i] = 255;
          } else if (pixel >= this.lowThresh) {
              output[i] = 100;
          } else {
              output[i] = 0;
          }
      }

      return output;
  }

  hysteresis(image) {
      const width = image.width;
      const height = image.height;
      const output = new Uint8Array(width * height);

      for (let y = 1; y < height - 1; y++) {
          for (let x = 1; x < width - 1; x++) {
              const idx = y * width + x;
              if (image[idx] === 100) {
                  if (image[idx - width - 1] === 255 || image[idx - width] === 255 || image[idx - width + 1] === 255 ||
                      image[idx - 1] === 255 || image[idx + 1] === 255 ||
                      image[idx + width - 1] === 255 || image[idx + width] === 255 || image[idx + width + 1] === 255) {
                      output[idx] = 255;
                  }
              } else if (image[idx] === 255) {
                  output[idx] = 255;
              }
          }
      }

      return output;
  }

  detectEdges(imageData) {
      const width = imageData.width;
      const height = imageData.height;
      const grayImage = new Float32Array(width * height);

      // Convert image to grayscale
      for (let i = 0; i < imageData.data.length; i += 4) {
          const r = imageData.data[i];
          const g = imageData.data[i + 1];
          const b = imageData.data[i + 2];
          const gray = 0.299 * r + 0.587 * g + 0.114 * b;
          grayImage[i / 4] = gray;
      }

      // Apply Gaussian blur
      const blurredImage = this.applyKernel({ data: grayImage, width, height }, this.gaussianKernel);

      // Apply Sobel operator
      const { Gx, Gy } = this.sobelOperator({ data: blurredImage, width, height });

      // Compute gradient magnitude and direction
      const { magnitude, direction } = this.gradientMagnitudeAndDirection(Gx, Gy, width, height);

      // Non-maximum suppression
      const suppressedImage = this.nonMaximumSuppression(magnitude, direction, width, height);

      // Double thresholding
      const thresholdedImage = this.doubleThresholding({ data: suppressedImage, width, height });

      // Edge tracking by hysteresis
      const finalImage = this.hysteresis({ data: thresholdedImage, width, height });

      return finalImage;
  }
}

class LinePolar {
  constructor(rho, angle) {
      this.rho = rho;
      this.angle = angle;
  }
}

class HoughTransform {
  constructor() {}

  static computeNumangle(min_theta, max_theta, theta_step) {
      let numangle = Math.floor((max_theta - min_theta) / theta_step) + 1;
      if (numangle > 1 && Math.abs(Math.PI - (numangle - 1) * theta_step) < theta_step / 2) {
          --numangle;
      }
      return numangle;
  }

  static createTrigTable(numangle, min_theta, theta_step, irho, tabSin, tabCos) {
      let ang = min_theta;
      for (let n = 0; n < numangle; ang += theta_step, n++) {
          tabSin[n] = Math.sin(ang) * irho;
          tabCos[n] = Math.cos(ang) * irho;
      }
  }

  static findLocalMaximums(numrho, numangle, threshold, accum, sort_buf) {
      for (let r = 0; r < numrho; r++) {
          for (let n = 0; n < numangle; n++) {
              let base = (n + 1) * (numrho + 2) + r + 1;
              if (
                  accum[base] > threshold &&
                  accum[base] > accum[base - 1] && accum[base] >= accum[base + 1] &&
                  accum[base] > accum[base - numrho - 2] && accum[base] >= accum[base + numrho + 2]
              ) {
                  sort_buf.push(base);
              }
          }
      }
  }

  static hough_cmp_gt(aux) {
      return function (l1, l2) {
          return aux[l1] > aux[l2] || (aux[l1] === aux[l2] && l1 < l2);
      };
  }

  static HoughLinesStandard(image, rho, theta, threshold, linesMax, min_theta, max_theta) {
      let height = image.length;
      let width = image[0].length;
      let irho = 1 / rho;
      let numangle = this.computeNumangle(min_theta, max_theta, theta);
      let numrho = Math.round(((width + height) * 2 + 1) / rho);

      let accum = Array((numangle + 2) * (numrho + 2)).fill(0);
      let tabSin = new Array(numangle);
      let tabCos = new Array(numangle);
      let sort_buf = [];

      this.createTrigTable(numangle, min_theta, theta, irho, tabSin, tabCos);

      for (let i = 0; i < height; i++) {
          for (let j = 0; j < width; j++) {
              if (image[i][j] !== 0) {
                  for (let n = 0; n < numangle; n++) {
                      let r = Math.round(j * tabCos[n] + i * tabSin[n]);
                      r += (numrho - 1) / 2;
                      accum[(n + 1) * (numrho + 2) + r + 1]++;
                  }
              }
          }
      }

      this.findLocalMaximums(numrho, numangle, threshold, accum, sort_buf);
      sort_buf.sort(this.hough_cmp_gt(accum));

      let lines = [];
      for (let i = 0; i < Math.min(linesMax, sort_buf.length); i++) {
          let idx = sort_buf[i];
          let n = Math.floor(idx / (numrho + 2)) - 1;
          let r = idx - (n + 1) * (numrho + 2) - 1;
          lines.push(new LinePolar((r - (numrho - 1) * 0.5) * rho, min_theta + n * theta));
      }

      return lines;
  }

  static HoughLinesProbabilistic(image, rho, theta, threshold, lineLength, lineGap, linesMax) {
      let height = image.length;
      let width = image[0].length;
      let irho = 1 / rho;
      let numangle = this.computeNumangle(0.0, Math.PI, theta);
      let numrho = Math.round(((width + height) * 2 + 1) / rho);

      let accum = Array(numangle * numrho).fill(0);
      let tabSin = new Array(numangle);
      let tabCos = new Array(numangle);
      let edges = [];

      this.createTrigTable(numangle, 0.0, theta, irho, tabSin, tabCos);

      for (let y = 0; y < height; y++) {
          for (let x = 0; x < width; x++) {
              if (image[y][x] !== 0) {
                  edges.push([x, y]);
              }
          }
      }

      for (let edge of edges) {
          let [x, y] = edge;
          for (let n = 0; n < numangle; n++) {
              let r = Math.round(x * tabCos[n] + y * tabSin[n]);
              r += (numrho - 1) / 2;
              accum[n * numrho + r]++;
          }
      }

      let sort_buf = [];
      this.findLocalMaximums(numrho, numangle, threshold, accum, sort_buf);
      sort_buf.sort(this.hough_cmp_gt(accum));

      let lines = [];
      for (let i = 0; i < Math.min(linesMax, sort_buf.length); i++) {
          let idx = sort_buf[i];
          let n = Math.floor(idx / numrho);
          let r = idx - n * numrho;
          let rhoValue = (r - (numrho - 1) * 0.5) * rho;
          let thetaValue = n * theta;
          lines.push([rhoValue, thetaValue]);
      }

      let rng = () => Math.floor(Math.random() * (edges.length));

      let segments = [];
      for (let edge of edges) {
          let [x, y] = edge;
          for (let line of lines) {
              let [rhoValue, thetaValue] = line;
              let x0 = Math.round((rhoValue - y * Math.sin(thetaValue)) / Math.cos(thetaValue));
              let y0 = Math.round((rhoValue - x * Math.cos(thetaValue)) / Math.sin(thetaValue));
              let x1 = x0, y1 = y0;

              for (let gap = 0; gap < lineGap; gap++) {
                  if (image[y0] && image[y0][x0]) {
                      if (Math.abs(x1 - x0) >= lineLength || Math.abs(y1 - y0) >= lineLength) {
                          segments.push([x0, y0, x1, y1]);
                      }
                      if (image[y1] && image[y1][x1]) {
                          x1 = x0 + (Math.abs(x1 - x0) >= lineLength ? 0 : 1);
                          y1 = y0 + (Math.abs(y1 - y0) >= lineLength ? 0 : 1);
                      }
                  }
              }
          }
      }

      return segments;
  }
}

// Usage example:
// Note: `image` should be a 2D array where non-zero values represent edges.
// let hough = new HoughTransform();
// let lines = HoughTransform.HoughLinesStandard(image, 1, Math.PI / 180, 100, 50, 0, Math.PI);
// let probLines = HoughTransform.HoughLinesProbabilistic(image, 1, Math.PI / 180, 100, 50, 10, 50);

const fs = require('fs');
const jpeg = require('jpeg-js');

// Assuming CannyEdgeDetector and HoughTransform classes are already defined

// Function to convert an image buffer to grayscale
function bufferToGrayScale(imageData) {
  const { data, width, height } = imageData;
  const grayPixels = new Float32Array(width * height);

  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const gray = 0.299 * r + 0.587 * g + 0.114 * b;
    grayPixels[i / 4] = gray;
  }

  return { data: grayPixels, width, height };
}

async function detectLines(filePath) {
  const buffer = fs.readFileSync(filePath);
  const rawImageData = jpeg.decode(buffer, { useTArray: true });

  const imageData = bufferToGrayScale(rawImageData);

  const edgeDetector = new CannyEdgeDetector(50, 150);
  const edges = edgeDetector.detectEdges(imageData);

  console.log(edges.length, edges.filter(a => a > 0).length)

  const edgeImage = {
    data: edges,
    width: imageData.width,
    height: imageData.height
  };

  // Convert edge image data to 2D array
  const edgeImage2D = [];
  for (let y = 0; y < edgeImage.height; y++) {
    const row = [];
    for (let x = 0; x < edgeImage.width; x++) {
      row.push(edgeImage.data[y * edgeImage.width + x]);
    }
    edgeImage2D.push(row);
  }

  const lines = HoughTransform.HoughLinesProbabilistic(edgeImage2D, 1, Math.PI / 180, 100, 50, 10, 50);

  let boundingBoxes = [];
  let imgWidth = edgeImage.width;
  let imgHeight = edgeImage.height;

  for (let i = 0; i < lines.length; i++) {
    let [rho, theta] = lines[i];
    let x1, y1, x2, y2;

    if (Math.sin(theta) !== 0) { // Vertical lines
      x1 = Math.round(rho / Math.cos(theta));
      y1 = 0;
      x2 = Math.round((rho - imgHeight * Math.sin(theta)) / Math.cos(theta));
      y2 = imgHeight;
    } else { // Horizontal lines
      x1 = 0;
      y1 = Math.round(rho / Math.sin(theta));
      x2 = imgWidth;
      y2 = Math.round((rho - imgWidth * Math.cos(theta)) / Math.sin(theta));
    }

    // Ensure the line is either horizontal or vertical
    let dx = x2 - x1;
    let dy = y2 - y1;

    if (Math.abs(dx) < 5) { // Consider as vertical line if x1 ≈ x2
      x1 = x2 = Math.round((x1 + x2) / 2); // Make it perfectly vertical
      let x = x1 / imgWidth;
      let y = (imgHeight - Math.min(y1, y2)) / imgHeight;
      let height = Math.abs(y1 - y2) / imgHeight;
      boundingBoxes.push({ "text": "|", "origin": { "x": x, "y": y }, "size": { "width": 0, "height": height } });
    } else if (Math.abs(dy) < 5) { // Consider as horizontal line if y1 ≈ y2
      y1 = y2 = Math.round((y1 + y2) / 2); // Make it perfectly horizontal
      let x = Math.min(x1, x2) / imgWidth;
      let y = (imgHeight - y1) / imgHeight;
      let width = Math.abs(x1 - x2) / imgWidth;
      boundingBoxes.push({ "text": "_", "origin": { "x": x, "y": y }, "size": { "width": width, "height": 0 } });
    }
  }

  return boundingBoxes;
}

// Usage example
(async () => {
  const filePath = './randompage.jpg'; // Change to your image path
  const boundingBoxes = await detectLines(filePath);
  console.log('Bounding Boxes:', boundingBoxes);
})();
