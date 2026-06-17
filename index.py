#!/usr/bin/env python3
"""CLI wrapper for the Python ascii-screenshot port. Mirrors index.js interface."""

import argparse
import sys

parser = argparse.ArgumentParser(description="ascii-screenshot (Python port)")
parser.add_argument("image", help="Path to image file")
parser.add_argument("--px", type=float, default=None, help="Normalized X coordinate (0-1) for pointer")
parser.add_argument("--py", type=float, default=None, help="Normalized Y coordinate (0-1) for pointer")
parser.add_argument("--width", type=int, default=160, help="Canvas width (default: 160)")
parser.add_argument("--height", type=int, default=None, help="Canvas height (default: auto from aspect ratio)")
parser.add_argument("--ocr", choices=["rapidocr", "apple"], default="rapidocr", help="OCR backend (default: rapidocr)")

args = parser.parse_args()

from ascii_screenshot import (
    RapidOCRBackend, AppleVisionBackend,
    ocr_image, detect_lines, ascii, _get_backend, set_ocr_backend,
)

if args.ocr == "apple":
    set_ocr_backend(AppleVisionBackend())
else:
    set_ocr_backend(RapidOCRBackend())

if args.px is not None or args.py is not None:
    import cv2, math

    backend = _get_backend()
    ocr_data = backend.run(args.image)
    if ocr_data is None:
        print("OCR failed", file=sys.stderr)
        sys.exit(1)

    img = cv2.imread(args.image)
    if img is None:
        print("Cannot read image", file=sys.stderr)
        sys.exit(1)
    img_h, img_w = img.shape[:2]

    canvas_height = args.height
    if canvas_height is None:
        canvas_height = min(100, max(1, math.floor(args.width * img_h / img_w * 0.5)))

    line_data = detect_lines(args.image, img_w, img_h)
    result = ascii(ocr_data, line_data, args.px, args.py, args.width, canvas_height)
    print(result["finalText"])
else:
    result = ocr_image(args.image, canvas_width=args.width, canvas_height=args.height)
    if result is None:
        print("OCR failed", file=sys.stderr)
        sys.exit(1)
    print(result)
