import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ascii_screenshot import detect_lines


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = str(Path(self.temp.name) / "image.png")

    def detect(self, image):
        self.assertTrue(cv2.imwrite(self.path, image))
        h, w = image.shape[:2]
        python = detect_lines(self.path, w, h)
        node = subprocess.run(
            ["node", "-e", "require('./detect_lines').detectLines(process.argv[1])"
             ".then(x => console.log(JSON.stringify(x)))", self.path],
            cwd=ROOT, text=True, capture_output=True, check=True,
        )
        self.assertEqual(python, json.loads(node.stdout))
        self.assertEqual(python[-4:], [
            {"text": "|", "origin": {"x": 0, "y": 0}, "size": {"width": 0, "height": 1}},
            {"text": "|", "origin": {"x": 1, "y": 0}, "size": {"width": 0, "height": 1}},
            {"text": "_", "origin": {"x": 0, "y": 0}, "size": {"width": 1, "height": 0}},
            {"text": "_", "origin": {"x": 0, "y": 1}, "size": {"width": 1, "height": 0}},
        ])
        return python[:-4]

    def assert_boundary(self, lines, orientation, position, start, end):
        along, across = ("x", "y") if orientation == "_" else ("y", "x")
        length = "width" if orientation == "_" else "height"
        self.assertTrue(any(
            line["text"] == orientation
            and abs(line["origin"][across] - position) < 0.015
            and line["origin"][along] <= start + 0.015
            and line["origin"][along] + line["size"][length] >= end - 0.015
            for line in lines
        ), (orientation, position, lines))

    def test_filled_regions_without_border_strokes(self):
        for scale in (1, 2):
            with self.subTest(scale=scale):
                image = np.full((400 * scale, 600 * scale, 3), 255, np.uint8)
                image[:, :150 * scale] = (245, 247, 249)
                image[:80 * scale, 150 * scale:] = (50, 80, 110)
                lines = self.detect(image)
                self.assert_boundary(lines, "|", 0.25, 0, 1)
                self.assert_boundary(lines, "_", 0.2, 0.25, 1)

    def test_faint_card_edges_and_cell_fills(self):
        image = np.full((400, 600, 3), 255, np.uint8)
        image[80:320, 100:500] = (250, 248, 246)
        image[200:320, 300:500] = (200, 210, 220)
        lines = self.detect(image)
        for x in (100 / 600, 500 / 600):
            self.assert_boundary(lines, "|", x, 0.2, 0.8)
        for y in (0.2, 0.8):
            self.assert_boundary(lines, "_", y, 100 / 600, 500 / 600)
        self.assert_boundary(lines, "|", 0.5, 0.5, 0.8)

    def test_thin_rules_are_merged_once(self):
        image = np.full((400, 600, 3), 255, np.uint8)
        image[100:102, 50:550] = 100
        image[40:360, 300:302] = 100
        lines = self.detect(image)
        self.assert_boundary(lines, "_", 0.25, 50 / 600, 550 / 600)
        self.assert_boundary(lines, "|", 0.5, 0.1, 0.9)
        self.assertEqual(len(lines), 2)

    def test_texture_and_faint_background_stripes_are_not_panels(self):
        rng = np.random.default_rng(17)
        texture = rng.integers(0, 256, (400, 600, 3), dtype=np.uint8)
        self.assertEqual(self.detect(texture), [])
        stripes = np.full((400, 600, 3), 70, np.uint8)
        stripes[:, 5::10] = 76
        self.assertEqual(self.detect(stripes), [])

    def test_table_with_differently_coloured_cells(self):
        image = np.full((400, 600, 3), 255, np.uint8)
        image[60:340, 60:300] = (230, 240, 250)
        image[60:340, 300:540] = (250, 230, 240)
        image[198:200, 60:540] = 80
        self.assert_boundary(self.detect(image), "_", 0.5, 0.1, 0.9)

    def test_blank_and_small_images_keep_only_frame(self):
        for h, w in ((400, 600), (1, 1), (10, 10)):
            with self.subTest(size=(h, w)):
                self.assertEqual(self.detect(np.full((h, w, 3), 255, np.uint8)), [])


if __name__ == "__main__":
    unittest.main()
