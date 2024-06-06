document.getElementById('upload').addEventListener('change', handleImageUpload);

function handleImageUpload(event) {
    const file = event.target.files[0];
    if (!file) {
        return;
    }
    const img = new Image();
    img.onload = () => {
        const canvas = document.getElementById('canvas');
        const ctx = canvas.getContext('2d');
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0);
        detectBorders(canvas, img.width, img.height);
    };
    img.src = URL.createObjectURL(file);
}

function detectBorders(canvas, width, height) {
    const src = cv.imread(canvas);
    const gray = new cv.Mat();
    cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY, 0);

    // Apply Gaussian Blur
    const blurred = new cv.Mat();
    cv.GaussianBlur(gray, blurred, new cv.Size(5, 5), 0, 0, cv.BORDER_DEFAULT);

    // Apply Canny Edge Detection
    const edges = new cv.Mat();
    cv.Canny(blurred, edges, 50, 150);

    // Apply Morphological Operations
    const kernel = cv.Mat.ones(3, 3, cv.CV_8U);
    const morphed = new cv.Mat();
    cv.morphologyEx(edges, morphed, cv.MORPH_CLOSE, kernel);

    const lines = new cv.Mat();
    const color = new cv.Scalar(255, 0, 0, 255); // Set color to red
    const lineType = cv.LINE_AA;

    // Increase the threshold for HoughLinesP and adjust parameters
    cv.HoughLinesP(morphed, lines, 1, Math.PI / 180, 200, 100, 10);

    const horizontalLines = [];
    const verticalLines = [];

    // Separate lines into horizontal and vertical arrays
    for (let i = 0; i < lines.rows; ++i) {
        const [x1, y1, x2, y2] = lines.intPtr(i);
        if (Math.abs(y1 - y2) < 10) {
            horizontalLines.push({ x1, y1, x2, y2 });
        } else if (Math.abs(x1 - x2) < 10) {
            verticalLines.push({ x1, y1, x2, y2 });
        }
    }

    // Find the two longest horizontal and vertical lines
    horizontalLines.sort((a, b) => Math.abs(b.x2 - b.x1) - Math.abs(a.x2 - a.x1));
    verticalLines.sort((a, b) => Math.abs(b.y2 - b.y1) - Math.abs(a.y2 - a.y1));

    const longestHorizontalLines = horizontalLines.slice(0, 2);
    const longestVerticalLines = verticalLines.slice(0, 2);

    console.log('Longest horizontal lines:', longestHorizontalLines);
    console.log('Longest vertical lines:', longestVerticalLines);

    // Function to check if a line qualifies based on bounding lines
    function qualifiesLine(line, lines, isHorizontal) {
        const { x1, y1, x2, y2 } = line;
        const point1 = isHorizontal ? x1 : y1;
        const point2 = isHorizontal ? x2 : y2;
        let minBound = -Infinity;
        let maxBound = Infinity;

        for (let l of lines) {
            if (isHorizontal) {
                if (l.x1 < point1 && l.x2 < point1) {
                    minBound = Math.max(minBound, l.x1);
                }
                if (l.x1 > point2 && l.x2 > point2) {
                    maxBound = Math.min(maxBound, l.x1);
                }
            } else {
                if (l.y1 < point1 && l.y2 < point1) {
                    minBound = Math.max(minBound, l.y1);
                }
                if (l.y1 > point2 && l.y2 > point2) {
                    maxBound = Math.min(maxBound, l.y1);
                }
            }
        }

        const span = isHorizontal ? width : height;
        const qualifies = (point1 - minBound) >= 0.6 * span && (maxBound - point2) >= 0.6 * span;
        console.log(`Line (${x1}, ${y1}) -> (${x2}, ${y2}) qualifies: ${qualifies}`);
        return qualifies;
    }

    // Recursive function to add qualifying lines
    function addQualifyingLines(lines, isHorizontal) {
        let addedLines = [];
        for (let line of lines) {
            if (qualifiesLine(line, isHorizontal ? verticalLines : horizontalLines, isHorizontal)) {
                addedLines.push(line);
                console.log(`Added ${isHorizontal ? 'horizontal' : 'vertical'} line:`, line);
            } else {
                console.log(`Discarded ${isHorizontal ? 'horizontal' : 'vertical'} line:`, line);
            }
        }
        return addedLines;
    }

    // Add qualifying horizontal lines
    let displayedHorizontalLines = addQualifyingLines(horizontalLines, true);
    let displayedVerticalLines = addQualifyingLines(verticalLines, false);

    // Post-processing step to add a border around the entire image
    cv.line(src, new cv.Point(0, 0), new cv.Point(width - 1, 0), color, 2, lineType); // Top border
    cv.line(src, new cv.Point(0, 0), new cv.Point(0, height - 1), color, 2, lineType); // Left border
    cv.line(src, new cv.Point(0, height - 1), new cv.Point(width - 1, height - 1), color, 2, lineType); // Bottom border
    cv.line(src, new cv.Point(width - 1, 0), new cv.Point(width - 1, height - 1), color, 2, lineType); // Right border

    // Draw horizontal lines
    for (let { x1, y1, x2, y2 } of displayedHorizontalLines) {
        cv.line(src, new cv.Point(x1, y1), new cv.Point(x2, y2), color, 2, lineType);
    }

    // Draw vertical lines
    for (let { x1, y1, x2, y2 } of displayedVerticalLines) {
        cv.line(src, new cv.Point(x1, y1), new cv.Point(x2, y2), color, 2, lineType);
    }

    cv.imshow('canvas', src);
    src.delete();
    gray.delete();
    blurred.delete();
    edges.delete();
    morphed.delete();
    lines.delete();
}
