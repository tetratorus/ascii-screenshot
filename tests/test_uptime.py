import contextlib
from datetime import datetime
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "macos" / "uptime.py"
SPEC = importlib.util.spec_from_file_location("screen_uptime", PATH)
uptime = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = uptime
SPEC.loader.exec_module(uptime)


class UptimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.history = self.home / ".ascii-screen" / "history"
        self.history.mkdir(parents=True)
        with sqlite3.connect(self.history / "index.sqlite") as db:
            db.execute("CREATE TABLE frames(id INTEGER PRIMARY KEY, time REAL)")
            db.execute("CREATE VIRTUAL TABLE words USING fts5(text, content='', detail=none)")

    def add(self, stamp, text):
        with sqlite3.connect(self.history / "index.sqlite") as db:
            frame_id = db.execute("INSERT INTO frames(time) VALUES (?)", (stamp,)).lastrowid
            db.execute("INSERT INTO words(rowid,text) VALUES (?,?)", (frame_id, text))

    def test_counts_unique_words_and_capture_gaps_without_screen_text(self):
        self.add(100, "hello hello world")
        self.add(160, "hello")
        self.add(1100, "a later screen")
        before = (self.history / "index.sqlite").read_bytes()
        data = uptime.read_activity(self.history, 0, 1200, 1250)
        self.assertEqual(data["frames"], 3)
        self.assertEqual([b["words_per_frame"] for b in data["buckets"] if b["frames"]], [2, 1, 3])
        self.assertEqual(data["latest_age_seconds"], 150)
        self.assertEqual(data["gaps"][0], {"start": 160, "end": 1100, "seconds": 940})
        self.assertNotIn("hello", str(data))
        self.assertEqual((self.history / "index.sqlite").read_bytes(), before)
        rendered = uptime.render(data, "running")
        self.assertIn("Mac screen capture history", rendered)
        self.assertIn("NO RECENT CAPTURES", rendered)
        self.assertIn("not an uptime percentage", rendered)

    def test_empty_range_preserves_latest_capture_and_service_status(self):
        self.add(1100, "screen")
        data = uptime.read_activity(self.history, 0, 600, 1120)
        self.assertEqual(data["frames"], 0)
        self.assertEqual(data["latest_capture"], 1100)
        self.assertIn("RECORDER STOPPED", uptime.render(data, "stopped"))
        self.assertEqual(sum(b["frames"] for b in data["buckets"]), 0)

    def test_cli_defaults_to_mac_history_and_checks_mac_service(self):
        self.add(1100, "private screen text")
        output = io.StringIO()
        with patch.object(Path, "home", return_value=self.home), \
                patch.object(uptime.time, "time", return_value=1200), \
                patch.object(uptime.subprocess, "run",
                             return_value=subprocess.CompletedProcess([], 0, " state = running\n")) as run, \
                contextlib.redirect_stdout(output):
            self.assertEqual(uptime.main(["--json"]), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["frames"], 1)
        self.assertEqual(result["service"], "running")
        self.assertNotIn("private", output.getvalue())
        self.assertEqual(run.call_args.args[0][-1],
                         f"gui/{uptime.os.getuid()}/com.tetratorus.ascii-screen")

    def test_missing_history_reports_error_without_creating_a_database(self):
        missing = self.home / "missing"
        with contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(uptime.main(["--history", str(missing), "--once"]), 1)
        self.assertIn("Cannot read capture history", error.getvalue())
        self.assertFalse(missing.exists())

    def test_axis_has_seven_readable_labels(self):
        start = datetime(2026, 11, 16, 16, 0).timestamp()
        ticks, labels = uptime.time_axis(start, start + 3600, 60)
        self.assertEqual(ticks.count("┬"), 7)
        self.assertEqual(labels.split(), ["16:00", "16:10", "16:20", "16:30", "16:40", "16:50", "17:00"])
        _, labels = uptime.time_axis(start, start + 60, 66)
        self.assertEqual(len(labels.split()), 7)
        self.assertIn("16:00:10", labels)

    def test_zoom_pan_and_return_to_live(self):
        view = uptime.View()
        self.assertEqual(view.window(7200), (3600, 7200))
        view.key("+", 7200)
        self.assertEqual(view.span, 1800)
        view.key("-", 7200)
        view.key("\x1b[D", 7200)
        self.assertEqual(view.window(9000), (1800, 5400))
        view.key("L", 9000)
        self.assertEqual(view.window(9000), (5400, 9000))
        for _ in range(20):
            view.key("+", 9000)
        self.assertEqual(view.span, 60)
        for _ in range(20):
            view.key("-", 9000)
        self.assertEqual(view.span, 604800)
        self.assertFalse(view.key("q", 9000))

    def test_capture_runs_keep_exact_times_and_end_boundary(self):
        for stamp in (100, 105, 500, 600):
            self.add(stamp, "test")
        data = uptime.read_activity(self.history, 0, 600, 600, columns=60)
        self.assertEqual(data["capture_runs"], [
            {"start": 100, "end": 105, "frames": 2},
            {"start": 500, "end": 500, "frames": 1},
            {"start": 600, "end": 600, "frames": 1},
        ])
        self.assertEqual(data["buckets"][-1]["frames"], 1)
        self.assertEqual(sum(b["frames"] for b in data["buckets"]), 4)
        self.assertIn("Each cell = 10s", uptime.render(data, "running"))


if __name__ == "__main__":
    unittest.main()
