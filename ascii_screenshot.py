"""
Port of tetratorus/ascii-screenshot to Python.

Core algorithm:
  1. OCR engine extracts text + bounding boxes (swappable backend)
  2. formatText() places OCR fragments into a monospace character grid
     using their normalized X,Y positions
  3. groupWordsInSentence() merges nearby fragments into words
  4. addLinesToAsciiText() overlays detected visual lines (|, _)
  5. ascii() orchestrates the pipeline

OCR backends:
  - "rapidocr" — RapidOCR (cross-platform, requires rapidocr-onnxruntime)
  - "apple"    — macOS Vision framework via osascript (macOS only)

Original JS: https://github.com/tetratorus/ascii-screenshot
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import subprocess
import sys
from typing import Any, Protocol

import cv2
import numpy as np

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 1. OCR interface + backends
# ---------------------------------------------------------------------------

# Annotation format consumed by the rest of the pipeline:
#   {text: str, origin: {x: float, y: float}, size: {width: float, height: float}}
# All coordinates normalized 0–1.

Annotation = dict[str, Any]


class OCRBackend(Protocol):
    """Interface: image path in, list of normalised-bbox annotations out."""

    def run(self, image_path: str) -> list[Annotation] | None: ...


# ---- RapidOCR backend -----------------------------------------------------

# Regex for splitting concatenated CamelCase / letter-digit text
_WORD_SPLIT_RE = re.compile(
    r"(?<=[a-z])(?=[A-Z])"          # lower → upper
    r"|(?<=[A-Z])(?=[A-Z][a-z])"   # upper → upper+lower
    r"|(?<=[a-zA-Z])(?=\d)"         # letter → digit
    r"|(?<=\d)(?=[a-zA-Z])"         # digit → letter
)


def _split_concatenated_text(text: str) -> list[str]:
    if not text:
        return []
    parts = text.split()
    result = []
    for part in parts:
        tokens = _WORD_SPLIT_RE.split(part)
        result.extend([t for t in tokens if t])
    return result


class RapidOCRBackend:
    """RapidOCR via rapidocr-onnxruntime. Cross-platform."""

    def __init__(self) -> None:
        self._engine: Any = None

    def _get_engine(self) -> Any:
        if self._engine is None:
            from rapidocr_onnxruntime import RapidOCR
            self._engine = RapidOCR()
        return self._engine

    def run(self, image_path: str) -> list[Annotation] | None:
        if not os.path.exists(image_path):
            logger.debug("OCR image not found: %s", image_path)
            return None
        try:
            img = cv2.imread(image_path)
            if img is None:
                return None

            ocr_result, _ = self._get_engine()(img)
            if not ocr_result:
                return []

            img_h, img_w = img.shape[:2]
            annotations: list[Annotation] = []

            for bbox, text, score in ocr_result:
                if not text or not bbox:
                    continue
                xs = [p[0] for p in bbox]
                ys = [p[1] for p in bbox]
                min_x, max_x = min(xs), max(xs)
                min_y, max_y = min(ys), max(ys)
                bbox_width = max(max_x - min_x, 1)

                # Convert to Apple Vision coordinate system (origin = bottom-left, y=0 at bottom)
                norm_height = (max_y - min_y) / img_h
                norm_y = 1.0 - max_y / img_h  # bottom-left of bbox in bottom-up coords

                words = _split_concatenated_text(text)
                if len(words) > 1:
                    total_len = sum(len(w) for w in words)
                    x_offset = min_x
                    for word in words:
                        word_width = (len(word) / total_len) * bbox_width if total_len > 0 else bbox_width
                        annotations.append({
                            "text": word,
                            "origin": {"x": x_offset / img_w, "y": norm_y},
                            "size": {"width": word_width / img_w, "height": norm_height},
                        })
                        x_offset += word_width
                else:
                    annotations.append({
                        "text": text,
                        "origin": {"x": min_x / img_w, "y": norm_y},
                        "size": {"width": (max_x - min_x) / img_w, "height": norm_height},
                    })

            logger.debug("RapidOCR extracted %d fragments from %s", len(annotations), image_path)
            return annotations
        except Exception:
            logger.debug("RapidOCR failed for %s", image_path, exc_info=True)
            return None


# ---- Apple Vision backend --------------------------------------------------

class AppleVisionBackend:
    """macOS Vision framework via osascript. Returns normalised bounding boxes natively."""

    def __init__(self, scpt_path: str | None = None) -> None:
        self._scpt_path = scpt_path

    def _find_scpt(self) -> str:
        if self._scpt_path:
            return self._scpt_path
        # Look next to this file, then in common locations
        here = os.path.dirname(os.path.abspath(__file__))
        candidates = [
            os.path.join(here, "ocr.scpt"),
            os.path.join(here, "..", "..", "ocr.scpt"),
        ]
        for c in candidates:
            if os.path.exists(c):
                return c
        raise FileNotFoundError("ocr.scpt not found — pass scpt_path to AppleVisionBackend")

    def run(self, image_path: str) -> list[Annotation] | None:
        if sys.platform != "darwin":
            logger.debug("AppleVisionBackend requires macOS")
            return None
        if not os.path.exists(image_path):
            logger.debug("OCR image not found: %s", image_path)
            return None
        try:
            scpt = self._find_scpt()
            proc = subprocess.run(
                ["osascript", scpt, image_path],
                capture_output=True, text=True, timeout=30,
            )
            if proc.returncode != 0:
                logger.debug("osascript failed: %s", proc.stderr)
                return None
            # JXA console.log writes to stderr, which can also carry system log noise
            output = proc.stderr or proc.stdout
            json_line = next(
                (line for line in reversed(output.splitlines()) if line.startswith("[")),
                None,
            )
            if json_line is None:
                logger.debug("osascript returned no OCR JSON: %s", output)
                return None
            annotations: list[Annotation] = json.loads(json_line)
            logger.debug("AppleVision extracted %d fragments from %s", len(annotations), image_path)
            return annotations
        except Exception:
            logger.debug("AppleVision failed for %s", image_path, exc_info=True)
            return None


# ---- Backend selection -----------------------------------------------------

_default_backend: OCRBackend | None = None


def set_ocr_backend(backend: OCRBackend) -> None:
    """Set the OCR backend used by ocr_image()."""
    global _default_backend
    _default_backend = backend


def _get_backend() -> OCRBackend:
    global _default_backend
    if _default_backend is None:
        _default_backend = RapidOCRBackend()
    return _default_backend


# ---------------------------------------------------------------------------
# 2. formatText() — spatial canvas rendering (ported from ascii.js)
# ---------------------------------------------------------------------------


def format_text(
    ocr_data: list[dict[str, Any]], canvas_width: int, canvas_height: int
) -> str:
    """Place OCR fragments into a monospace character grid at their X,Y positions.

    Port of formatText() from ascii.js.
    """
    # Cluster annotations by Y-row
    line_cluster: dict[int, list[dict[str, Any]]] = {}
    for annotation in ocr_data:
        # Invert Y: JS does (1 - origin.y) * canvasHeight
        y_key = math.floor((1 - annotation["origin"]["y"]) * canvas_height)
        line_cluster.setdefault(y_key, []).append(annotation)

    # Create blank canvas
    canvas: list[list[str]] = []
    for _ in range(canvas_height):
        canvas.append([" "] * canvas_width)

    # Place text, grouped by line — use y_key as actual row (not enumeration index)
    for y_key, line in line_cluster.items():
        row = min(y_key, canvas_height - 1)
        if row < 0:
            row = 0
        line.sort(key=lambda a: a["origin"]["x"])
        grouped = group_words_in_sentence(line)

        last_x = 0
        for annotation in grouped:
            text: str = annotation["text"]
            x = math.floor(annotation["origin"]["x"] * canvas_width)
            start_x = max(x, last_x)

            # Extend canvas if text overflows
            if start_x + len(text) >= canvas_width:
                for _ in range(len(text) + 1):
                    canvas[row].append(" ")

            for j, ch in enumerate(text):
                if start_x + j < canvas_width:
                    canvas[row][start_x + j] = ch

            last_x = start_x + len(text) + 1  # +1 for inter-word space

    page_text = "\n".join("".join(row[:canvas_width]) for row in canvas)
    bordered = "_" * canvas_width + "\n" + page_text + "\n" + "_" * canvas_width
    return bordered


# ---------------------------------------------------------------------------
# 3. Word grouping (ported from ascii.js)
# ---------------------------------------------------------------------------


def group_words_in_sentence(
    line_annotations: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Group nearby text fragments into words using character-width heuristics.

    Port of groupWordsInSentence() from ascii.js.
    """
    grouped: list[dict[str, Any]] = []
    current_group: list[dict[str, Any]] = []

    for annotation in line_annotations:
        if not current_group:
            current_group.append(annotation)
            continue

        previous = current_group[-1]
        prev_width = previous["size"]["width"]
        prev_text_len = len(previous["text"])
        char_width = (prev_width / prev_text_len) * 2 if prev_text_len > 0 else prev_width
        next_start_x = previous["origin"]["x"] + prev_width

        if annotation["origin"]["x"] <= next_start_x + char_width:
            # Adjacent — merge into current group
            current_group.append(annotation)
        else:
            # New group
            grouped.append(create_grouped_annotation(current_group))
            current_group = [annotation]

    if current_group:
        grouped.append(create_grouped_annotation(current_group))

    return grouped


def create_grouped_annotation(group: list[dict[str, Any]]) -> dict[str, Any]:
    """Merge a group of adjacent text fragments into a single annotation.

    Port of createGroupedAnnotation() from ascii.js.
    """
    separators = {".", ",", '"', "'", ":", ";", "!", "?", "{", "}", "\u2019", "\u201d"}

    text_parts: list[str] = []
    for idx, word in enumerate(group):
        if word["text"] in separators:
            text_parts.append(word["text"])
        else:
            if idx > 0:
                text_parts.append(" ")
            text_parts.append(word["text"])

    text = "".join(text_parts)

    return {
        "text": text,
        "origin": {
            "x": group[0]["origin"]["x"],
            "y": group[0]["origin"]["y"],
        },
        "size": {
            "width": sum(w["size"]["width"] for w in group),
            "height": group[0]["size"]["height"],
        },
    }


# ---------------------------------------------------------------------------
# 4. Line detection (ported from detect_lines.js)
# ---------------------------------------------------------------------------


def detect_lines(
    image_path: str, img_w: int, img_h: int
) -> list[dict[str, Any]]:
    """Detect UI borders and separators as horizontal/vertical line segments.

    Finds long runs of colour change between adjacent pixel rows/columns,
    merges runs that belong to the same edge, and drops edges with texture on
    both sides (photos). Mirrors detectLines() in detect_lines.js.
    """
    try:
        img = cv2.imread(image_path, cv2.IMREAD_COLOR)
        if img is None:
            return _edge_lines()
        img = img.astype(np.int16)
        h, w = img.shape[:2]
        tol = max(2, _round(h * EDGE_TOL_FRAC))

        h_edges = np.abs(img[1:] - img[:-1]).max(axis=2) >= EDGE_THRESHOLD
        v_edges = (np.abs(img[:, 1:] - img[:, :-1]).max(axis=2) >= EDGE_THRESHOLD).T
        horizontal = [
            c for c in _merge_runs(_runs(h_edges, _round(w * MIN_LINE_FRAC)), tol)
            if _has_flat_side(img, c, tol)
        ]
        vertical = [
            c for c in _merge_runs(_runs(v_edges, _round(h * MIN_LINE_FRAC)), tol)
            if _has_flat_side(img.transpose(1, 0, 2), c, tol)
        ]

        lines = [
            {
                "text": "|",
                "origin": {"x": (p0 + p1) / 2 / w, "y": a / h},
                "size": {"width": 0, "height": (b - a) / h},
            }
            for p0, p1, a, b in vertical
        ] + [
            {
                "text": "_",
                "origin": {"x": a / w, "y": (p0 + p1) / 2 / h},
                "size": {"width": (b - a) / w, "height": 0},
            }
            for p0, p1, a, b in horizontal
        ]
        return lines + _edge_lines()

    except Exception:
        logger.debug("Line detection failed for %s", image_path, exc_info=True)
        return _edge_lines()


EDGE_THRESHOLD = 4  # include faint panel fills, not just high-contrast rules
STRONG_EDGE_THRESHOLD = 10
MIN_LINE_FRAC = 0.025  # min line length as a fraction of image width/height
EDGE_TOL_FRAC = 0.004  # merge tolerance as a fraction of image height
FLAT_TOL = 0  # max per-channel distance from the chunk median for a pixel to count as solid
FLAT_PIX_FRAC = 0.9  # min fraction of solid pixels for a chunk to count as flat
FLAT_CHUNK = 4  # flatness is checked in chunks of FLAT_CHUNK * merge tolerance
FLAT_MIN_FRAC = 0.5  # min fraction of chunks with a flat side to keep an edge


def _round(x: float) -> int:
    return math.floor(x + 0.5)


def _runs(mask: np.ndarray, min_len: int) -> list[tuple[int, int, int]]:
    """(row, start, end) for each run of True along each row with length >= min_len."""
    padded = np.zeros((mask.shape[0], mask.shape[1] + 2), np.int8)
    padded[:, 1:-1] = mask
    d = np.diff(padded, axis=1)
    rows, starts = np.nonzero(d == 1)
    _, ends = np.nonzero(d == -1)
    keep = (ends - starts) >= min_len
    return list(zip(rows[keep].tolist(), starts[keep].tolist(), ends[keep].tolist()))


def _merge_runs(
    runs: list[tuple[int, int, int]], tol: int
) -> list[list[int]]:
    """Merge runs within `tol` rows of each other whose spans overlap or nearly touch.

    Returns [first_row, last_row, start, end] per merged edge.
    """
    edges: list[list[int]] = []
    for row, a, b in sorted(runs):
        target = None
        for e in reversed(edges):
            if row - e[0] > tol:
                break
            if a <= e[3] + tol and b >= e[2] - tol:
                target = e
                break
        if target is None:
            edges.append([row, row, a, b])
        else:
            target[1] = row
            target[2] = min(target[2], a)
            target[3] = max(target[3], b)
    return edges


def _has_flat_side(img: np.ndarray, edge: list[int], offset: int) -> bool:
    """True if, along most of the edge, the strip just before or after it is a solid colour.

    UI fills repeat the exact same pixel value; smooth photo regions do not.

    Checked in chunks so a separator between differently coloured cells still counts.
    """
    p0, p1, a, b = edge
    before, after = p0 - offset + 1, p1 + offset
    if before >= 0 and after < img.shape[0]:
        across = np.abs(img[before, a:b] - img[after, a:b]).max(axis=1) >= EDGE_THRESHOLD
        strong = np.abs(img[p0 + 1:p1 + 2, a:b] - img[p0:p1 + 1, a:b]).max(axis=(0, 2)) >= STRONG_EDGE_THRESHOLD
        # Reject faint narrow stripes whose two surrounding regions are the same.
        if (across | strong).mean() < FLAT_MIN_FRAC:
            return False
    n = b - a
    n_chunks = max(1, n // (offset * FLAT_CHUNK))
    flat = np.zeros(n_chunks, bool)
    for r in (p0 - offset + 1, p1 + offset):
        if 0 <= r < img.shape[0]:
            strip = img[r, a:b]
            for i in range(n_chunks):
                chunk = strip[i * n // n_chunks:(i + 1) * n // n_chunks]
                near = np.abs(chunk - np.median(chunk, axis=0)).max(axis=1) <= FLAT_TOL
                if near.mean() >= FLAT_PIX_FRAC:
                    flat[i] = True
    return flat.mean() >= FLAT_MIN_FRAC


def _edge_lines() -> list[dict[str, Any]]:
    """Return the four edge/border lines."""
    return [
        {"text": "|", "origin": {"x": 0, "y": 0}, "size": {"width": 0, "height": 1}},
        {"text": "|", "origin": {"x": 1, "y": 0}, "size": {"width": 0, "height": 1}},
        {"text": "_", "origin": {"x": 0, "y": 0}, "size": {"width": 1, "height": 0}},
        {"text": "_", "origin": {"x": 0, "y": 1}, "size": {"width": 1, "height": 0}},
    ]


# ---------------------------------------------------------------------------
# 5. addLinesToAsciiText() — line overlay (ported from ascii.js)
# ---------------------------------------------------------------------------


def add_lines_to_ascii(
    ascii_lines: str,
    line_data: list[dict[str, Any]],
    canvas_width: int,
    canvas_height: int,
) -> dict[str, str]:
    """Overlay detected separator lines onto the ASCII canvas.

    Port of addLinesToAsciiText() from ascii.js.
    """
    # Create line-only canvas
    lines_canvas: list[list[str]] = []
    for _ in range(canvas_height):
        lines_canvas.append([" "] * canvas_width)

    for line in line_data:
        if line["text"] == "|":
            x = min(math.floor(line["origin"]["x"] * canvas_width), canvas_width - 1)
            start_y = max(math.floor(line["origin"]["y"] * canvas_height), 0)
            end_y = min(
                math.floor((line["origin"]["y"] + line["size"]["height"]) * canvas_height),
                canvas_height - 1,
            )
            for y in range(start_y, end_y + 1):
                lines_canvas[y][x] = "+" if lines_canvas[y][x] in ("_", "+") else "|"

        elif line["text"] == "_":
            y = min(math.floor(line["origin"]["y"] * canvas_height), canvas_height - 1)
            start_x = max(math.floor(line["origin"]["x"] * canvas_width), 0)
            end_x = min(
                start_x + math.floor(line["size"]["width"] * canvas_width),
                canvas_width - 1,
            )
            for x in range(start_x, end_x + 1):
                lines_canvas[y][x] = "+" if lines_canvas[y][x] in ("|", "+") else "_"

    lines_text = "\n".join("".join(row) for row in lines_canvas)

    # Merge: overlay lines onto ASCII text
    ascii_rows = ascii_lines.split("\n")[1:-1]  # strip top/bottom borders
    final_rows: list[str] = []
    for row_idx, row in enumerate(ascii_rows):
        # Ensure lines canvas row is wide enough (format_text may extend rows)
        max_col = len(row)
        if row_idx < len(lines_canvas) and len(lines_canvas[row_idx]) < max_col:
            lines_canvas[row_idx].extend([" "] * (max_col - len(lines_canvas[row_idx])))
        new_row_chars: list[str] = []
        for col_idx, ch in enumerate(row):
            lc = lines_canvas[row_idx][col_idx] if row_idx < len(lines_canvas) and col_idx < len(lines_canvas[row_idx]) else " "
            if ch == "\U0001F446":
                new_row_chars.append(ch)
            elif ch == " " or lc in ("|", "+"):
                new_row_chars.append(lc)
            elif lc == "_":
                new_row_chars.append(ch + "\u0332")  # combining underline
            else:
                new_row_chars.append(ch)
        final_rows.append("".join(new_row_chars))

    final_text = "\n".join(final_rows)

    return {
        "originalText": ascii_lines,
        "linesText": lines_text,
        "finalText": final_text,
    }


# ---------------------------------------------------------------------------
# 6. ascii() — main orchestrator (ported from ascii.js)
# ---------------------------------------------------------------------------


def _is_text_edge(line: dict[str, Any], ocr_data: list[dict[str, Any]]) -> bool:
    """Reject glyph stems/underlines inside OCR boxes, not long structural edges."""
    vertical = line["text"] == "|"
    pos = line["origin"]["x" if vertical else "y"]
    start = line["origin"]["y" if vertical else "x"]
    length = line["size"]["height" if vertical else "width"]
    if length == 1 and pos in (0, 1):
        return False
    for box in ocr_data:
        top = 1 - box["origin"]["y"] - box["size"]["height"]
        lo = top if vertical else box["origin"]["x"]
        hi = lo + box["size"]["height" if vertical else "width"]
        side = box["origin"]["x"] if vertical else top
        side_end = side + box["size"]["width" if vertical else "height"]
        overlap = max(0, min(start + length, hi) - max(start, lo))
        if side <= pos <= side_end and length > 0 and overlap >= 0.8 * length:
            return True
    return False


def ascii(
    ocr_data: list[dict[str, Any]],
    line_data: list[dict[str, Any]],
    norm_x: float | None,
    norm_y: float | None,
    canvas_width: int = 80,
    canvas_height: int | None = None,
) -> dict[str, str]:
    """Main ASCII screenshot pipeline — identical logic to ascii.js.

    If canvas_height is None, it's calculated from image aspect ratio
    using the source image dimensions encoded in ocr_data's coordinate space.
    """
    if canvas_height is None:
        # Derive height from width and image aspect ratio
        # We estimate aspect ratio from the max X and Y in ocr data
        canvas_height = max(1, math.floor(canvas_width * 0.4))

    # Step 1. Format text into ASCII canvas
    original_ascii = format_text(ocr_data, canvas_width, canvas_height)

    # Step 2. Convert to mutable 2D array
    canvas_rows = [list(row) for row in original_ascii.split("\n")[1:-1]]

    # Step 3. Add cursor if coords provided
    if norm_x is not None and norm_y is not None:
        canvas_x = min(len(canvas_rows[0]) - 1, round(norm_x * len(canvas_rows[0])))
        canvas_y = min(len(canvas_rows) - 1, round(norm_y * len(canvas_rows)))
        if 0 <= canvas_y < len(canvas_rows) and 0 <= canvas_x < len(canvas_rows[canvas_y]):
            canvas_rows[canvas_y][canvas_x] = "\U0001F446"  # 👆

    # Step 4. Re-bracket
    page_text = "\n".join("".join(row) for row in canvas_rows)
    bordered = "_" * canvas_width + "\n" + page_text + "\n" + "_" * canvas_width

    # Step 5. Overlay detected lines
    structural_lines = [line for line in line_data if not _is_text_edge(line, ocr_data)]
    result = add_lines_to_ascii(bordered, structural_lines, canvas_width, canvas_height)

    return {"originalText": bordered, "linesText": result["linesText"], "finalText": result["finalText"]}


# ---------------------------------------------------------------------------
# 7. Top-level: ocr_image() — drop-in replacement for nanobot integration
# ---------------------------------------------------------------------------


def ocr_image(
    image_path: str,
    canvas_width: int = 80,
    canvas_height: int | None = None,
    backend: OCRBackend | None = None,
) -> str | None:
    """Run the full ascii-screenshot pipeline on an image.

    Returns the rendered ASCII text, or None if OCR fails.
    This is the function called by image_placeholder_text().
    """
    ocr_data = (backend or _get_backend()).run(image_path)
    if ocr_data is None:
        return None

    if not ocr_data:
        logger.debug("OCR returned empty result for %s", image_path)
        return None

    # Get image dimensions for line detection
    img = cv2.imread(image_path)
    if img is None:
        return None
    img_h, img_w = img.shape[:2]

    if canvas_height is None:
        canvas_height = max(1, math.floor(canvas_width * img_h / img_w * 0.5))
        # Clamp to reasonable range
        canvas_height = min(canvas_height, 100)

    # Run line detection
    line_data = detect_lines(image_path, img_w, img_h)

    # Run ascii pipeline
    result = ascii(ocr_data, line_data, None, None, canvas_width, canvas_height)
    return result["finalText"]
