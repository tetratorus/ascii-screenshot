const fs = require('fs');

// Function to read JSON data from a file
function readJsonFile(filePath) {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function formatText(boundingBoxData) {
    // Cluster tokens by line
    const lineCluster = {};
    boundingBoxData.forEach(annotation => {
        const midpointY = annotation.origin.y + annotation.size.height / 2;
        const closestLine = Object.keys(lineCluster).find(
            y => Math.abs(midpointY - y) < 0.02
        );

        if (closestLine) {
            lineCluster[closestLine].push(annotation);
        } else {
            lineCluster[midpointY] = [annotation];
        }
    });

    const canvasHeight = Object.keys(lineCluster).length;
    const defaultCanvasWidth = 80;

    // Determine canvas width
    let canvasWidth = defaultCanvasWidth;

    if (Object.keys(lineCluster).length > 0) {
        canvasWidth = Math.max(
            Math.max(
                ...Object.values(lineCluster).map(line =>
                    line.reduce((sum, token) => sum + token.text.length + 1, 0)
                ),
                defaultCanvasWidth
            )
        );
    }

    // Create an empty canvas
    const canvas = Array.from({ length: canvasHeight }, () =>
        Array(canvasWidth).fill(' ')
    );

    const letterHeight = 0.03;
    const emptySpaceHeight = letterHeight + 0.005;
    let maxPreviousLineHeight = emptySpaceHeight;

    // Place the annotations on the canvas
    let i = 0;
    Object.values(lineCluster).forEach(lineAnnotations => {
        // Sort annotations in this line by x coordinate
        lineAnnotations.sort((a, b) => a.origin.x - b.origin.x);

        const groupedLineAnnotations = groupWordsInSentence(lineAnnotations);

        // Use the TOP height of the letter
        const maxLineHeight = Math.max(
            ...groupedLineAnnotations.map(
                annotation => annotation.origin.y - annotation.size.height
            )
        );
        const heightToAdd = Math.floor(
            (maxLineHeight - maxPreviousLineHeight) / emptySpaceHeight
        );
        if (heightToAdd > 0) {
            for (let j = 0; j < heightToAdd; j++) {
                canvas.push(Array(canvasWidth).fill(' '));
                i++;
            }
        }

        // Store the BOTTOM height of the letter
        maxPreviousLineHeight = Math.max(
            ...groupedLineAnnotations.map(
                annotation => annotation.origin.y + annotation.size.height
            )
        );

        let lastX = 0;
        groupedLineAnnotations.forEach(annotation => {
            const text = annotation.text;

            let x = Math.floor(annotation.origin.x * canvasWidth);

            // Move forward if there's an overlap
            x = Math.max(x, lastX);

            // Check if the text fits; if not, move to next line (this is simplistic)
            if (x + text.length >= canvasWidth) {
                canvas[i].push(...Array(text.length + 1).fill(' '));
            }

            // Place the text on the canvas
            for (let j = 0; j < text.length; j++) {
                canvas[i][x + j] = text[j];
            }

            // Update the last inserted position
            lastX = x + text.length + 1; // +1 for a space between words
        });

        i++;
    });

    // Delete all whitespace characters after the last non-whitespace character in each row
    const trimmedCanvas = canvas.map(row => row.join('').trimRight());

    // Convert the canvas to a plaintext string
    let pageText = trimmedCanvas.join('\n').trim();

    pageText = '-'.repeat(canvasWidth) + '\n' + pageText + '\n' + '-'.repeat(canvasWidth);

    return pageText;
}

function groupWordsInSentence(lineAnnotations) {
    const groupedAnnotations = [];
    let currentGroup = [];

    lineAnnotations.forEach(annotation => {
        if (currentGroup.length === 0) {
            currentGroup.push(annotation);
            return;
        }

        const padding = 2;
        const characterWidth = (currentGroup[currentGroup.length - 1].size.width / currentGroup[currentGroup.length - 1].text.length) * padding;

        const isSingleCharacterAway = annotation.origin.x <= (currentGroup[currentGroup.length - 1].origin.x + currentGroup[currentGroup.length - 1].size.width) + characterWidth;

        if (Math.abs(annotation.size.height - currentGroup[0].size.height) <= 0.04 && isSingleCharacterAway) {
            currentGroup.push(annotation);
        } else {
            if (currentGroup.length > 0) {
                groupedAnnotations.push(createGroupedAnnotation(currentGroup));
                currentGroup = [annotation];
            }
        }
    });

    // Append the last group if it exists
    if (currentGroup.length > 0) {
        groupedAnnotations.push(createGroupedAnnotation(currentGroup));
    }

    return groupedAnnotations;
}

function createGroupedAnnotation(group) {
    let text = '';

    group.forEach(word => {
        if (['.', ',', '"', "'", ':', ';', '!', '?', '{', '}', '’', '”'].includes(word.text)) {
            text += word.text;
        } else {
            text += text !== '' ? ' ' + word.text : word.text;
        }
    });

    const isWord = text.length > 1 && /[a-zA-Z0-9]/.test(text);
    if (isWord && group.map(word => word.size.height).reduce((a, b) => a + b, 0) / group.length > 0.025) {
        text = '**' + text + '**';
    }

    return {
        text: text,
        origin: {
            x: group[0].origin.x,
            y: group[0].origin.y,
        },
        size: {
            width: group.reduce((sum, word) => sum + word.size.width, 0),
            height: group[0].size.height,
        }
    };
}

// Read the bounding box data from the JSON file
const boundingBoxData = readJsonFile('screenshot.json');
// Format the text
const formattedText = formatText(boundingBoxData);
// Print the formatted text
console.log(formattedText);
