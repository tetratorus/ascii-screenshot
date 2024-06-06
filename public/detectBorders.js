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

    const edges = new cv.Mat();
    cv.Canny(gray, edges, 50, 100);

    const lines = new cv.Mat();
    const color = new cv.Scalar(255, 0, 0, 255); // Set color to red
    const lineType = cv.LINE_AA;

    cv.HoughLinesP(edges, lines, 1, Math.PI / 180, 100, 100, 10); // Adjusted parameters

    for (let i = 0; i < lines.rows; ++i) {
        const [x1, y1, x2, y2] = lines.intPtr(i);
        const length = Math.sqrt(Math.pow(x2 - x1, 2) + Math.pow(y2 - y1, 2));
        if ((Math.abs(x1 - x2) < 10 || Math.abs(y1 - y2) < 10) && length > 50) { // Filter for horizontal and vertical lines, and length
            cv.line(src, new cv.Point(x1, y1), new cv.Point(x2, y2), color, 2, lineType); // Set color to red
        }
    }

    cv.imshow('canvas', src);
    src.delete();
    gray.delete();
    edges.delete();
    lines.delete();
}
