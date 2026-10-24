import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ascii_screenshot import add_lines_to_ascii, ascii


def line(text, x, y, width=0, height=0):
    return {"text": text, "origin": {"x": x, "y": y},
            "size": {"width": width, "height": height}}


class RenderingTests(unittest.TestCase):
    def compare(self, function, args):
        python_function = {"ascii": ascii, "addLinesToAsciiText": add_lines_to_ascii}[function]
        result = python_function(*args)
        node = subprocess.run(
            ["node", "-e", "const [fn,args]=JSON.parse(process.argv[1]);"
             "console.log(JSON.stringify(require('./ascii')[fn](...args)))",
             json.dumps([function, args])], cwd=ROOT, text=True, capture_output=True, check=True,
        )
        self.assertEqual(result, json.loads(node.stdout))
        return result

    def test_intersections_preserve_both_orientations_in_either_order(self):
        vertical = line("|", .5, 0, height=1)
        horizontal = line("_", 0, .5, width=1)
        for lines in ([vertical, horizontal], [horizontal, vertical]):
            with self.subTest(lines=lines):
                result = self.compare("addLinesToAsciiText", [
                    "__________\n" + (" " * 10 + "\n") * 6 + "__________", lines, 10, 6,
                ])
                rows = result["finalText"].splitlines()
                self.assertEqual(rows[3], "_____+____")
                self.assertTrue(all(row[5] in "|+" for row in rows))

    def test_vertical_boundaries_take_precedence_over_colliding_text(self):
        original = "__________\nABCDEFGHIJ\nABCDEFGHIJ\n__________"
        result = self.compare("addLinesToAsciiText", [original, [line("|", .4, 0, height=1)], 10, 2])
        self.assertEqual(result["originalText"], original)
        self.assertEqual(result["finalText"], "ABCD|FGHIJ\nABCD|FGHIJ")

    def test_horizontal_rule_keeps_text_with_combining_underline(self):
        result = self.compare("addLinesToAsciiText", [
            "____\nText\n____", [line("_", 0, 0, width=1)], 4, 1,
        ])
        self.assertEqual(result["finalText"], "T\u0332e\u0332x\u0332t\u0332")

    def test_ocr_glyph_edges_are_removed_but_long_structural_edges_remain(self):
        text = [line("Tables", .3, .6, width=.4, height=.2)]  # OCR: bottom-left origin
        glyph = line("|", .45, .22, height=.16)
        boundary = line("|", .3, .1, height=.8)
        frame = [line("|", 0, 0, height=1), line("_", 0, 1, width=1)]
        result = self.compare("ascii", [text, [glyph, boundary, *frame], None, None, 40, 10])
        rows = result["linesText"].splitlines()
        self.assertTrue(all(row[18] != "|" for row in rows))
        self.assertEqual(sum(row[12] in "|+" for row in rows), 9)
        self.assertTrue(all(row[0] in "|+" for row in rows))
        self.assertTrue(all(ch in "_+" for ch in rows[-1]))

    def test_cursor_takes_precedence_at_a_boundary_intersection(self):
        result = self.compare("ascii", [[], [line("|", .4, 0, height=1),
                                           line("_", 0, .4, width=1)], .4, .4, 20, 10])
        rows = result["finalText"].splitlines()
        self.assertEqual(rows[4][8], "\U0001F446")
        self.assertEqual(len(rows[4]), 20)
        self.assertEqual(result["finalText"].count("\U0001F446"), 1)

    def test_overflowing_text_does_not_extend_the_canvas(self):
        result = self.compare("ascii", [[line("long overflowing text", .8, .8, width=.2, height=.1)],
                                        [], None, None, 10, 5])
        self.assertTrue(all(len(row) == 10 for row in result["finalText"].splitlines()))


if __name__ == "__main__":
    unittest.main()
