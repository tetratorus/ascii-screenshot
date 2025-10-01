function addCursorToCanvas(canvas, normX, normY) {
  const canvasX = Math.floor(normX * canvas[0].length);
  const canvasY = Math.floor((1 - normY) * canvas.length);

  if (canvasY >= 0 && canvasY < canvas.length) {
    if (canvasX >= 0 && canvasX < canvas[canvasY].length) {
      canvas[canvasY][canvasX] = "👆"; // overwrite any char
    }
  }
  return canvas;
}


module.exports = { addCursorToCanvas };
