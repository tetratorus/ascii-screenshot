const defaultCanvasWidth = 160;
let canvasWidth = defaultCanvasWidth;
let canvasHeight = 60;

function formatText(ocrData) {
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

  // Object.values(lineCluster).forEach((line) => {
  //   const lineWidth = line.reduce(
  //     (acc, token) => acc + token.text.length + 1,
  //     0
  //   );
  //   canvasWidth = Math.max(canvasWidth, lineWidth);
  // });

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

  const pageText = canvas.map((row) => row.join("")).join("\n");
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

// Post-processing step to add horizontal and vertical lines
function addLinesToAsciiText(asciiLines, lineData) {
  // const linesCanvas = Array.from({ length: canvasHeight }, () => Array(canvasWidth).fill(' '));
  // problem with the above line, just do it the lame ass way with for loops
  const linesCanvas = [];
  for (let i = 0; i < canvasHeight; i++) {
    let row = [];
    for (let j = 0; j < canvasWidth; j++) {
      row.push(" ");
    }
    linesCanvas.push(row);
  }

  lineData.forEach((line) => {
    if (line.text === "|") {
      const x = Math.min(Math.floor(line.origin.x * canvasWidth), canvasWidth - 1);
      const startY = Math.max(Math.floor(line.origin.y * canvasHeight), 0);
      const endY = Math.min(
        Math.floor((line.origin.y + line.size.height) * canvasHeight),
        canvasHeight - 1
      );
      // console.log("startY", startY, "x", x)
      // console.log("endY", endY)
      for (let y = startY; y <= endY; y++) {
        linesCanvas[y][x] = "|";
      }
    } else if (line.text === "_") {
      const y = Math.min(Math.floor(line.origin.y * canvasHeight), canvasHeight - 1);
      const startX = Math.max(Math.floor(line.origin.x * canvasWidth), 0);
      const endX = Math.min(
        startX + Math.floor(line.size.width * canvasWidth),
        canvasWidth - 1
      );


      // console.log("startX", startX, "y", y)
      // console.log("endX", endX)
      for (let x = startX; x <= endX; x++) {
        linesCanvas[y][x] = "_";
      }
    }
  });

  // Convert linesCanvas to string
  const linesText = linesCanvas.map((row) => row.join("")).join("\n");

  // Merge lines with original ASCII text
  const finalCanvas = asciiLines
    .split("\n")
    .slice(1, -1)
    .map((row, rowIndex) => {
      return row
        .split("")
        .map((char, colIndex) => {
          if (char === " ") {
            return linesCanvas[rowIndex][colIndex];
          } else if (linesCanvas[rowIndex][colIndex] === "_") {
            return char + "\u0332"; // Combining diacritic for underline
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

// function ascii(ocrData, lineData) {
//   const originalAscii = formatText(ocrData);
//   const { originalText, linesText, finalText } = addLinesToAsciiText(
//     originalAscii,
//     lineData
//   );
//   return { originalText, linesText, finalText };
// }

function ascii(ocrData, lineData, normX, normY) {
  // Step 1. Format text into ASCII canvas string
  const originalAscii = formatText(ocrData);

  // Step 2. Convert that string back into a mutable 2D array (canvas)
  let canvas = originalAscii
    .split("\n")
    .slice(1, -1) // drop top + bottom borders
    .map(row => row.split(""));

  // Step 3. Add cursor if normalized coords were passed
  if (normX != null && normY != null) {
    const canvasX = Math.floor(normX * canvas[0].length);
    const canvasY = Math.floor((1 - normY) * canvas.length);

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
    lineData
  );

  return { originalText, linesText, finalText };
}


module.exports = {
  ascii,
  formatText,
  groupWordsInSentence,
  createGroupedAnnotation,
  addLinesToAsciiText,
}

