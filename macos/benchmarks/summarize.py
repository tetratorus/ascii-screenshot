import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import statistics


HEADER = re.compile(r"\*\*\* Sampled system activity \((.*?)\) \(([\d.]+)ms elapsed\) \*\*\*")
TASK = re.compile(r"^(.+?)\s{2,}(-?\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")


def parse_samples(text):
    headers = list(HEADER.finditer(text))
    for i, header in enumerate(headers):
        body = text[header.end():headers[i + 1].start() if i + 1 < len(headers) else len(text)]
        end = datetime.strptime(header[1], "%a %b %d %H:%M:%S %Y %z").timestamp() * 1000
        elapsed = float(header[2])
        power = {}
        for rail in ("CPU", "GPU", "ANE"):
            match = re.search(rf"^{rail} Power: ([\d.]+) mW$", body, re.MULTILINE)
            power[rail.lower() + "_mw"] = float(match[1]) if match else None
        tasks = {}
        for line in body.splitlines():
            match = TASK.match(line)
            if match:
                tasks[int(match[2])] = {
                    "cpu_ms_per_s": float(match[3]),
                    "interrupt_wakeups_per_s": float(match[7]),
                    "idle_wakeups_per_s": float(match[8]),
                    "energy_impact": float(match[9]),
                }
        yield {
            "end": end, "start": end - elapsed, "elapsed_ms": elapsed,
            "invalid": bool(re.search(r"invalid\s*[=:]\s*true|underflow", body, re.IGNORECASE)),
            "tasks": tasks, **power,
        }


def summarize(events, samples):
    starts = {}
    results = []
    for event in events:
        if event["event"] == "start":
            starts[event["name"]] = event
        elif event["event"] == "end" and event["name"] in starts:
            start = starts[event["name"]]
            selected = [s for s in samples if s["start"] >= start["time"] + 1000 and s["end"] <= event["time"] - 1000]
            valid = [s for s in selected if not s["invalid"]]
            row = {
                "name": event["name"], "kind": start["kind"], "workload": start["workload"],
                "seconds": (event["time"] - start["time"]) / 1000,
                "samples": len(valid), "invalid_samples": len(selected) - len(valid),
            }
            for metric in ("cpu_mw", "gpu_mw", "ane_mw", "cpu_ms_per_s", "interrupt_wakeups_per_s", "idle_wakeups_per_s", "energy_impact"):
                values = []
                for sample in valid:
                    value = sample.get(metric) if metric.endswith("_mw") else sample["tasks"].get(start["pid"], {}).get(metric)
                    if value is not None and math.isfinite(value) and (metric.endswith("_mw") or start["kind"] == "native"):
                        values.append((value, sample["elapsed_ms"]))
                row[metric] = sum(v * weight for v, weight in values) / sum(weight for _, weight in values) if values else None
                row[metric + "_median"] = statistics.median(v for v, _ in values) if values else None
                row[metric + "_samples"] = len(values)
            results.append(row)
    return results


def table(rows):
    columns = [
        ("Run", "name"), ("Samples", "samples"), ("CPU mW", "cpu_mw"), ("GPU mW", "gpu_mw"),
        ("ANE mW", "ane_mw"), ("Process CPU ms/s", "cpu_ms_per_s"),
        ("Idle wakeups/s", "idle_wakeups_per_s"), ("Energy Impact*", "energy_impact"),
    ]
    out = ["| " + " | ".join(label for label, _ in columns) + " |", "|" + "---|" * len(columns)]
    for row in rows:
        out.append("| " + " | ".join("N/A" if row[key] is None else f"{row[key]:.1f}" if isinstance(row[key], float) else str(row[key]) for _, key in columns) + " |")
    return "\n".join(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("events", type=Path)
    parser.add_argument("power", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    rows = summarize([json.loads(line) for line in args.events.read_text().splitlines()], list(parse_samples(args.power.read_text())))
    print(json.dumps(rows, indent=2) if args.json else table(rows))
    if not args.json:
        print("\nRail power is system-wide, not app-attributed. Values are elapsed-time-weighted means; warmup and boundary samples are excluded.")
        print("*Energy Impact is powermetrics' process estimate, not an Activity Monitor UI reading. Legacy subprocess energy is not attributed.")
