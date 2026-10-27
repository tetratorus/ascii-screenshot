function formatText(ocrData, canvasWidth, canvasHeight) {
  const lineCluster = [];
  for (let i = 0; i < canvasHeight; i++) {
    lineCluster.push([]);
  }
  ocrData.forEach((annotation) => {
    const yKey = Math.floor((1 - annotation.origin.y) * canvasHeight); // Normalize and cluster by y-coordinate
    if (!lineCluster[yKey]) {
      lineCluster[yKey] = [];
    }
    lineCluster[yKey].push(annotation);
  });

  const canvas = [];
  for (let i = 0; i < canvasHeight; i++) {
    let row = [];
    for (let j = 0; j < canvasWidth; j++) {
      row.push(" ");
    }
    canvas.push(row);
  }

  Object.entries(lineCluster)
    .sort((a, b) => a[0] - b[0])
    .forEach(([_, line], i) => {
      line.sort((a, b) => a.origin.x - b.origin.x);
      const groupedLineAnnotations = groupWordsInSentence(line);

      let lastX = 0;
      groupedLineAnnotations.forEach((annotation) => {
        const text = annotation.text;
        const x = Math.floor(annotation.origin.x * canvasWidth);

        const startX = Math.max(x, lastX);
        if (startX + text.length >= canvasWidth) {
          canvas[i] = canvas[i].concat(Array(text.length + 1).fill(" "));
        }

        text.split("").forEach((char, j) => {
          if (startX + j < canvasWidth) {
            canvas[i][startX + j] = char;
          }
        });

        lastX = startX + text.length + 1;
      });
    });

  const pageText = canvas.map((row) => row.slice(0, canvasWidth).join("")).join("\n");
  const borderedText =
    "_".repeat(canvasWidth) + "\n" + pageText + "\n" + "_".repeat(canvasWidth);

  return borderedText;
}

function groupWordsInSentence(lineAnnotations) {
  const groupedAnnotations = [];
  let currentGroup = [];

  lineAnnotations.forEach((annotation) => {
    if (currentGroup.length === 0) {
      currentGroup.push(annotation);
      return;
    }

    const previous = currentGroup[currentGroup.length - 1];
    const characterWidth = (previous.size.width / previous.text.length) * 2; // Use width of last char in the group
    const nextStartX = previous.origin.x + previous.size.width;

    if (annotation.origin.x <= nextStartX + characterWidth) {
      currentGroup.push(annotation);
    } else {
      groupedAnnotations.push(createGroupedAnnotation(currentGroup));
      currentGroup = [annotation];
    }
  });

  if (currentGroup.length > 0) {
    groupedAnnotations.push(createGroupedAnnotation(currentGroup));
  }

  return groupedAnnotations;
}

function createGroupedAnnotation(group) {
  let text = group.reduce((acc, word, index) => {
    const separators = [
      ".",
      ",",
      '"',
      "'",
      ":",
      ";",
      "!",
      "?",
      "{",
      "}",
      "’",
      "”",
    ];
    if (separators.includes(word.text)) {
      return acc + word.text;
    } else {
      return acc + (index > 0 ? " " : "") + word.text;
    }
  }, "");

  const isWord = text.split("").some((char) => char.match(/\w/));
  // if (isWord && group.map(word => word.size.height).sort((a, b) => b - a)[Math.floor(group.length / 2)] > 0.025) { // Example threshold
  //     text = "**" + text + "**";
  // }

  return {
    text: text,
    origin: {
      x: group[0].origin.x,
      y: group[0].origin.y,
    },
    size: {
      width: group.reduce((acc, word) => acc + word.size.width, 0),
      height: group[0].size.height,
    },
  };
}

const UNDERLINE = "\u0332";

// Post-processing step to add horizontal and vertical lines.
// "_" draws a boundary along the bottom of its cell, so a box renders as:
//    ______        top row: "_" only, corners blank; verticals start on the next row
//   |      |
//   |______|       bottom row: verticals end here; "|" marks every junction
function addLinesToAsciiText(asciiLines, lineData, canvasWidth, canvasHeight) {
  const clampX = (x) => Math.max(0, Math.min(x, canvasWidth - 1));
  const clampY = (y) => Math.max(0, Math.min(y, canvasHeight - 1));
  const horizontals = [];
  const verticals = [];
  lineData.forEach((line) => {
    if (line.text === "|") {
      verticals.push({
        x: clampX(Math.floor(line.origin.x * canvasWidth)),
        y0: clampY(Math.floor(line.origin.y * canvasHeight)),
        y1: clampY(Math.floor((line.origin.y + line.size.height) * canvasHeight)),
      });
    } else if (line.text === "_") {
      const x0 = clampX(Math.floor(line.origin.x * canvasWidth));
      horizontals.push({
        y: clampY(Math.floor(line.origin.y * canvasHeight)),
        x0,
        x1: clampX(x0 + Math.floor(line.size.width * canvasWidth)),
      });
    }
  });
  snapCorners(horizontals, verticals);

  const linesCanvas = [];
  for (let i = 0; i < canvasHeight; i++) {
    let row = [];
    for (let j = 0; j < canvasWidth; j++) {
      row.push(" ");
    }
    linesCanvas.push(row);
  }
  horizontals.forEach(({ y, x0, x1 }) => {
    for (let x = x0; x <= x1; x++) linesCanvas[y][x] = "_";
  });
  verticals.forEach(({ x, y0, y1 }) => {
    for (let y = y0; y <= y1; y++) linesCanvas[y][x] = "|";
  });
  // Blank top corners so box tops read " ____ " rather than overhanging the verticals.
  verticals
    .filter(({ x, y0 }) => y0 > 0 && linesCanvas[y0 - 1][x] === "_" &&
      (linesCanvas[y0 - 1][x - 1] === "_") !== (linesCanvas[y0 - 1][x + 1] === "_"))
    .forEach(({ x, y0 }) => { linesCanvas[y0 - 1][x] = " "; });

  // Convert linesCanvas to string
  const linesText = linesCanvas.map((row) => row.join("")).join("\n");

  // Merge lines with original ASCII text
  const finalCanvas = asciiLines
    .split("\n")
    .slice(1, -1)
    .map((row, rowIndex) => {
      return Array.from(row)
        .map((char, colIndex) => {
          const line = linesCanvas[rowIndex]?.[colIndex] ?? " ";
          if (char === "👆") { // Cursor icon takes priority
            return "👆";
          } else if (char === " " || line === "|") {
            return line;
          } else if (line === "_") {
            return char + UNDERLINE;
          } else {
            return char;
          }
        })
        .join("");
    });

  // TODO: add back missing top border
  const finalText = finalCanvas.join("\n");

  return { originalText: asciiLines, linesText, finalText };
}

// Quantising to the coarse grid leaves line ends that should meet off by a cell.
// Pull horizontal ends onto nearby verticals, then start verticals on the row below a
// horizontal they hang from and end them on the row of one they stand on.
function snapCorners(horizontals, verticals) {
  const nearest = (candidates, target) => candidates.reduce(
    (best, c) => (best === null || Math.abs(c - target) < Math.abs(best - target) ? c : best), null);
  horizontals.forEach((h) => {
    const cols = verticals.filter(v => h.y >= v.y0 - 1 && h.y <= v.y1 + 1).map(v => v.x);
    const x0 = nearest(cols.filter(x => Math.abs(x - h.x0) <= 1), h.x0);
    const x1 = nearest(cols.filter(x => Math.abs(x - h.x1) <= 1), h.x1);
    if (x0 !== null) h.x0 = x0;
    if (x1 !== null) h.x1 = x1;
  });
  verticals.forEach((v) => {
    const rows = horizontals.filter(h => v.x >= h.x0 && v.x <= h.x1).map(h => h.y);
    const top = nearest(rows.filter(y => Math.abs(y - v.y0) <= 1), v.y0);
    const bottom = nearest(rows.filter(y => Math.abs(y - v.y1) <= 1), v.y1);
    if (top !== null && top === bottom) return; // a short vertical crossing one rule
    if (top !== null) v.y0 = top + 1;
    if (bottom !== null) v.y1 = bottom;
  });
  for (let i = verticals.length - 1; i >= 0; i--) {
    if (verticals[i].y0 > verticals[i].y1) verticals.splice(i, 1);
  }
}

// function ascii(ocrData, lineData) {
//   const originalAscii = formatText(ocrData);
//   const { originalText, linesText, finalText } = addLinesToAsciiText(
//     originalAscii,
//     lineData
//   );
//   return { originalText, linesText, finalText };
// }

function ascii(ocrData, lineData, normX, normY, canvasWidth, canvasHeight) {
  // Step 1. Format text into ASCII canvas string
  const originalAscii = formatText(ocrData, canvasWidth, canvasHeight);

  // Step 2. Convert that string back into a mutable 2D array (canvas)
  let canvas = originalAscii
    .split("\n")
    .slice(1, -1) // drop top + bottom borders
    .map(row => Array.from(row));

  // Step 3. Add cursor if normalized coords were passed
  if (normX != null && normY != null) {
    const canvasX = Math.min(canvas[0].length - 1, Math.round(normX * canvas[0].length));
    const canvasY = Math.min(canvas.length - 1, Math.round((normY) * canvas.length));

    if (canvasY >= 0 && canvasY < canvas.length) {
      if (canvasX >= 0 && canvasX < canvas[canvasY].length) {
        canvas[canvasY][canvasX] = "👆"; // overwrite any char
      }
    }
  }

  // Step 4. Turn back into string with borders
  const pageText = canvas.map(row => row.join("")).join("\n");
  const borderedText =
    "_".repeat(canvasWidth) + "\n" + pageText + "\n" + "_".repeat(canvasWidth);

  // Step 5. Overlay detected lines
  const { originalText, linesText, finalText } = addLinesToAsciiText(
    borderedText,
    lineData.filter(line => !isTextEdge(line, ocrData)),
    canvasWidth,
    canvasHeight,
  );

  return { originalText, linesText, finalText };
}

// Glyph stems/underlines can look like boundaries, but lie inside OCR text boxes.
function isTextEdge(line, ocrData) {
  const vertical = line.text === "|";
  const pos = line.origin[vertical ? "x" : "y"];
  const start = line.origin[vertical ? "y" : "x"];
  const length = line.size[vertical ? "height" : "width"];
  if (length === 1 && (pos === 0 || pos === 1)) return false;
  return ocrData.some(box => {
    const top = 1 - box.origin.y - box.size.height;
    const lo = vertical ? top : box.origin.x;
    const hi = lo + box.size[vertical ? "height" : "width"];
    const side = vertical ? box.origin.x : top;
    const sideEnd = side + box.size[vertical ? "width" : "height"];
    const overlap = Math.max(0, Math.min(start + length, hi) - Math.max(start, lo));
    return pos >= side && pos <= sideEnd && length > 0 && overlap >= 0.8 * length;
  });
}


module.exports = {
  ascii,
  formatText,
  groupWordsInSentence,
  createGroupedAnnotation,
  addLinesToAsciiText,
}
