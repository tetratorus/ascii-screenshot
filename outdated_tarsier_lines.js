function formatText(ocrData) {
  const lineCluster = {};
  ocrData.forEach(annotation => {
      const yKey = Math.floor(100 - annotation.origin.y * 100); // Normalize and cluster by y-coordinate
      if (!lineCluster[yKey]) {
          lineCluster[yKey] = [];
      }
      lineCluster[yKey].push(annotation);
  });

  const canvasHeight = Object.keys(lineCluster).length;
  const defaultCanvasWidth = 80;
  let canvasWidth = defaultCanvasWidth;

  Object.values(lineCluster).forEach(line => {
      const lineWidth = line.reduce((acc, token) => acc + token.text.length + 1, 0);
      canvasWidth = Math.max(canvasWidth, lineWidth);
  });

  const canvas = Array.from({ length: canvasHeight }, () => Array(canvasWidth).fill(' '));

  Object.entries(lineCluster).sort((a, b) => a[0] - b[0]).forEach(([_, line], i) => {
      line.sort((a, b) => a.origin.x - b.origin.x);
      const groupedLineAnnotations = groupWordsInSentence(line);

      let lastX = 0;
      groupedLineAnnotations.forEach(annotation => {
          const text = annotation.text;
          const x = Math.floor(annotation.origin.x * canvasWidth);

          const startX = Math.max(x, lastX);
          if (startX + text.length >= canvasWidth) {
              canvas[i] = canvas[i].concat(Array(text.length + 1).fill(' '));
          }

          text.split('').forEach((char, j) => {
              if (startX + j < canvasWidth) {
                  canvas[i][startX + j] = char;
              }
          });

          lastX = startX + text.length + 1;
      });
  });

  const pageText = canvas.map(row => row.join('').trimRight()).join('\n');
  const borderedText = '-'.repeat(canvasWidth) + '\n' + pageText + '\n' + '-'.repeat(canvasWidth);

  return borderedText;
}

function groupWordsInSentence(lineAnnotations) {
  const groupedAnnotations = [];
  let currentGroup = [];

  lineAnnotations.forEach(annotation => {
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
      const separators = [".", ",", '"', "'", ":", ";", "!", "?", "{", "}", "’", "”"];
      if (separators.includes(word.text)) {
          return acc + word.text;
      } else {
          return acc + (index > 0 ? " " : "") + word.text;
      }
  }, '');

  const isWord = text.split('').some(char => char.match(/\w/));
  if (isWord && group.map(word => word.size.height).sort((a, b) => b - a)[Math.floor(group.length / 2)] > 0.025) { // Example threshold
      text = "**" + text + "**";
  }

  return {
      text: text,
      origin: {
          x: group[0].origin.x,
          y: group[0].origin.y
      },
      size: {
          width: group.reduce((acc, word) => acc + word.size.width, 0),
          height: group[0].size.height
      }
  };
}

// Example usage with OCR data
const ocrData = require('./lines.json')
console.log(formatText(ocrData));
