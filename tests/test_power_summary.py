import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / "macos" / "benchmarks" / "summarize.py"
SPEC = importlib.util.spec_from_file_location("power_summary", PATH)
summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summary)


class PowerSummaryTests(unittest.TestCase):
    def test_rails_and_process_columns(self):
        text = """*** Sampled system activity (Sat Jan 01 00:00:02 2000 +0000) (1000.00ms elapsed) ***
ascii-screen     123  24.0  80.0  0.0  0.0  3.0  2.0  7.0
CPU Power: 500 mW
GPU Power: 20 mW
ANE Power: 10 mW
GPU Power: 999 mW
"""
        sample = list(summary.parse_samples(text))[0]
        self.assertEqual(sample["gpu_mw"], 20)
        self.assertEqual(sample["tasks"][123]["idle_wakeups_per_s"], 2)
        self.assertEqual(sample["tasks"][123]["interrupt_wakeups_per_s"], 3)
        self.assertEqual(sample["tasks"][123]["energy_impact"], 7)
        self.assertEqual(sample["end"] - sample["start"], 1000)

    def test_excludes_boundaries_invalid_samples_and_missing_processes(self):
        events = [
            {"event": "start", "time": 10000, "name": "test", "pid": 123, "kind": "native", "workload": "static"},
            {"event": "end", "time": 20000, "name": "test"},
        ]
        def sample(start, end, invalid=False, tasks=None):
            return {"start": start, "end": end, "elapsed_ms": end - start, "invalid": invalid,
                    "cpu_mw": 500, "gpu_mw": 20, "ane_mw": 10, "tasks": tasks or {}}
        samples = [
            sample(9500, 10500),
            sample(11000, 12000, tasks={123: {"energy_impact": 4}}),
            sample(12000, 14000, tasks={123: {"energy_impact": 10}}),
            sample(14000, 15000),
            sample(15000, 16000, invalid=True),
            sample(19000, 20000),
        ]
        result = summary.summarize(events, samples)[0]
        self.assertEqual(result["samples"], 3)
        self.assertEqual(result["invalid_samples"], 1)
        self.assertEqual(result["energy_impact"], 8)
        self.assertEqual(result["energy_impact_samples"], 2)

    def test_legacy_wrapper_energy_is_not_misreported_as_pipeline_energy(self):
        events = [
            {"event": "start", "time": 0, "name": "old", "pid": 123, "kind": "legacy", "workload": "scroll"},
            {"event": "end", "time": 10000, "name": "old"},
        ]
        samples = [{"start": 2000, "end": 3000, "elapsed_ms": 1000, "invalid": False,
                    "tasks": {123: {"energy_impact": 0}}}]
        self.assertIsNone(summary.summarize(events, samples)[0]["energy_impact"])

    def test_interrupted_runs_are_not_reported_as_complete(self):
        events = [
            {"event": "start", "time": 0, "name": "test", "pid": 123, "kind": "native", "workload": "static"},
            {"event": "error", "time": 5000, "error": "interrupted"},
        ]
        self.assertEqual(summary.summarize(events, []), [])

    def test_invalid_sample_marker_is_preserved(self):
        text = """*** Sampled system activity (Sat Jan 01 00:00:02 2000 +0000) (1000.00ms elapsed) ***
invalid=true
CPU Power: 500 mW
"""
        self.assertTrue(list(summary.parse_samples(text))[0]["invalid"])
