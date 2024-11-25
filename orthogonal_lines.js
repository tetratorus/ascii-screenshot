const fs = require('fs');
const jpeg = require('jpeg-js');

class OrthogonalLineDetector {
    constructor(imageData) {
        this.width = imageData.width;
        this.height = imageData.height;
        this.data = imageData.data;
    }

    getEdgeMap(threshold = 128) {
        const edgeMap = new Array(this.height).fill(0)
            .map(() => new Array(this.width).fill(0));

        for (let y = 1; y < this.height - 1; y++) {
            for (let x = 1; x < this.width - 1; x++) {
                const idx = (y * this.width + x) * 4;
                const gray = (this.data[idx] * 0.299 +
                            this.data[idx + 1] * 0.587 +
                            this.data[idx + 2] * 0.114);

                if (gray > threshold) {
                    const surroundingPixels = [
                        this.getGrayValue(x - 1, y),
                        this.getGrayValue(x + 1, y),
                        this.getGrayValue(x, y - 1),
                        this.getGrayValue(x, y + 1)
                    ];

                    const adjacentEdges = surroundingPixels.filter(val => val > threshold).length;
                    edgeMap[y][x] = adjacentEdges >= 2 ? 1 : 0;
                }
            }
        }
        return edgeMap;
    }

    getGrayValue(x, y) {
        if (x < 0 || x >= this.width || y < 0 || y >= this.height) return 0;
        const idx = (y * this.width + x) * 4;
        return this.data[idx] * 0.299 + this.data[idx + 1] * 0.587 + this.data[idx + 2] * 0.114;
    }

    findLineSegments(edgeMap, isHorizontal) {
        const segments = [];
        const minLength = 30;
        const maxGap = 5;

        for (let primary = 0; primary < (isHorizontal ? this.height : this.width); primary++) {
            let segmentStart = -1;
            let gapStart = -1;
            let currentGapLength = 0;

            for (let secondary = 0; secondary < (isHorizontal ? this.width : this.height); secondary++) {
                const x = isHorizontal ? secondary : primary;
                const y = isHorizontal ? primary : secondary;
                const isEdge = edgeMap[y][x];

                if (isEdge) {
                    if (segmentStart === -1) {
                        segmentStart = secondary;
                    } else if (gapStart !== -1 && currentGapLength <= maxGap) {
                        gapStart = -1;
                        currentGapLength = 0;
                    }
                } else if (segmentStart !== -1) {
                    if (gapStart === -1) {
                        gapStart = secondary;
                        currentGapLength = 1;
                    } else {
                        currentGapLength++;
                        if (currentGapLength > maxGap) {
                            if (secondary - segmentStart >= minLength) {
                                segments.push({
                                    primary,
                                    start: segmentStart,
                                    end: gapStart - 1
                                });
                            }
                            segmentStart = -1;
                            gapStart = -1;
                            currentGapLength = 0;
                        }
                    }
                }
            }

            if (segmentStart !== -1 &&
                (isHorizontal ? this.width : this.height) - segmentStart >= minLength) {
                segments.push({
                    primary,
                    start: segmentStart,
                    end: (isHorizontal ? this.width : this.height) - 1
                });
            }
        }

        return this.mergeNearbySegments(segments, isHorizontal);
    }

    mergeNearbySegments(segments, isHorizontal) {
        if (!segments.length) return [];

        const maxPrimaryGap = 2;
        const merged = [];

        segments.sort((a, b) => a.primary - b.primary);

        let currentSegment = segments[0];

        for (let i = 1; i < segments.length; i++) {
            const nextSegment = segments[i];

            if (nextSegment.primary - currentSegment.primary <= maxPrimaryGap &&
                Math.abs(nextSegment.start - currentSegment.start) < 10 &&
                Math.abs(nextSegment.end - currentSegment.end) < 10) {
                currentSegment.primary = Math.floor((currentSegment.primary + nextSegment.primary) / 2);
                currentSegment.start = Math.min(currentSegment.start, nextSegment.start);
                currentSegment.end = Math.max(currentSegment.end, nextSegment.end);
            } else {
                merged.push(currentSegment);
                currentSegment = nextSegment;
            }
        }

        if (currentSegment) {
            merged.push(currentSegment);
        }

        return merged;
    }

    detectLines(edgeThreshold = 150) {
        const edgeMap = this.getEdgeMap(edgeThreshold);
        const results = [];

        const horizontalSegments = this.findLineSegments(edgeMap, true);
        for (const segment of horizontalSegments) {
            const width = (segment.end - segment.start) / this.width;
            results.push({
                text: "_",
                origin: {
                    x: segment.start / this.width,
                    y: (this.height - segment.primary) / this.height
                },
                size: {
                    width: width,
                    height: 0
                }
            });
        }

        const verticalSegments = this.findLineSegments(edgeMap, false);
        for (const segment of verticalSegments) {
            const height = (segment.end - segment.start) / this.height;
            results.push({
                text: "|",
                origin: {
                    x: segment.primary / this.width,
                    y: (this.height - segment.start) / this.height
                },
                size: {
                    width: 0,
                    height: height
                }
            });
        }

        return results;
    }
}

class ImageDrawer {
    constructor(imageData) {
        this.width = imageData.width;
        this.height = imageData.height;
        this.data = imageData.data;
    }

    drawLine(x1, y1, x2, y2, color = [255, 0, 0]) {
        const dx = Math.abs(x2 - x1);
        const dy = Math.abs(y2 - y1);
        const sx = x1 < x2 ? 1 : -1;
        const sy = y1 < y2 ? 1 : -1;
        let err = dx - dy;

        while (true) {
            this.setPixel(x1, y1, color);
            if (x1 === x2 && y1 === y2) break;
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x1 += sx;
            }
            if (e2 < dx) {
                err += dx;
                y1 += sy;
            }
        }
    }

    setPixel(x, y, color) {
        if (x < 0 || x >= this.width || y < 0 || y >= this.height) return;
        const idx = (y * this.width + x) * 4;
        this.data[idx] = color[0];
        this.data[idx + 1] = color[1];
        this.data[idx + 2] = color[2];
        this.data[idx + 3] = 255;
    }

    saveAsJpeg(outputPath) {
        const jpegImageData = jpeg.encode({
            data: this.data,
            width: this.width,
            height: this.height
        }, 100);
        fs.writeFileSync(outputPath, jpegImageData.data);
    }
}

function detectLinesInJpeg(imagePath, edgeThreshold = 150) {
    try {
        const jpegData = fs.readFileSync(imagePath);
        const rawImageData = jpeg.decode(jpegData);
        const detector = new OrthogonalLineDetector(rawImageData);
        return detector.detectLines(edgeThreshold);
    } catch (err) {
        throw err;
    }
}

function drawLinesOnImage(imagePath, outputPath, lines) {
    const jpegData = fs.readFileSync(imagePath);
    const rawImageData = jpeg.decode(jpegData);
    const drawer = new ImageDrawer(rawImageData);

    for (const line of lines) {
        if (line.text === "_") {
            const y = Math.floor(line.origin.y * rawImageData.height);
            const x1 = Math.floor(line.origin.x * rawImageData.width);
            const x2 = x1 + Math.floor(line.size.width * rawImageData.width);
            drawer.drawLine(x1, y, x2, y);
        } else if (line.text === "|") {
            const x = Math.floor(line.origin.x * rawImageData.width);
            const y1 = Math.floor(line.origin.y * rawImageData.height);
            const y2 = y1 - Math.floor(line.size.height * rawImageData.height);
            drawer.drawLine(x, y1, x, y2);
        }
    }

    drawer.saveAsJpeg(outputPath);
}

// Usage
const imagePath = 'new.jpg';
const outputPath = 'output_with_lines.jpg';

try {
    const lines = detectLinesInJpeg(imagePath);
    drawLinesOnImage(imagePath, outputPath, lines);
    console.log(`Lines drawn and saved to ${outputPath}`);
} catch (err) {
    console.error('Failed to process image:', err);
}
