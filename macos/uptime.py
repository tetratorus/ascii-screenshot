#!/usr/bin/env python3
"""Capture activity from ASCII Screen's local SQLite index. Never reads screen text."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import sqlite3
import subprocess
import sys
import termios
import time
import tty

ZOOM_SPANS = (60, 300, 900, 1800, 3600, 7200, 14400, 28800, 86400, 604800)


def parse_time(value, now):
    if value == "now":
        return now
    if value == "today":
        return datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    if re.fullmatch(r"(?:\d+(?:\.\d+)?[smhd])+", value):
        seconds = sum(float(n) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
                      for n, unit in re.findall(r"(\d+(?:\.\d+)?)([smhd])", value))
        return now - seconds
    if re.fullmatch(r"\d{1,2}:\d{2}(?::\d{2})?", value):
        parts = [int(n) for n in value.split(":")]
        return datetime.fromtimestamp(now).replace(hour=parts[0], minute=parts[1],
                                                   second=parts[2] if len(parts) == 3 else 0,
                                                   microsecond=0).timestamp()
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def duration(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h {seconds % 3600 // 60}m"


def service_status():
    try:
        result = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/com.tetratorus.ascii-screen"],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    if result.returncode:
        return "not loaded"
    return "running" if re.search(r"^\s*state = running$", result.stdout, re.M) else "stopped"


def read_activity(history, start, end, now, columns=72):
    # Open read-only: monitoring must not race the recorder by rebuilding its index.
    database = history / "index.sqlite"
    interval = (end - start) / columns
    buckets = [{"start": start + i * interval, "frames": 0, "word_total": 0}
               for i in range(columns)]
    with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=3) as db:
        db.execute("BEGIN")
        last = db.execute("SELECT MAX(time) FROM frames").fetchone()[0]
        records = db.execute(
            "SELECT id, time FROM frames WHERE time >= ? AND time <= ? ORDER BY time, id",
            (start, end),
        ).fetchall()
        words = {}
        if records:
            db.execute("CREATE VIRTUAL TABLE temp.word_instances USING fts5vocab(main, words, instance)")
            words = dict(db.execute(
                """SELECT v.doc, COUNT(*) FROM temp.word_instances v
                   JOIN main.frames f ON f.id = v.doc
                   WHERE f.time >= ? AND f.time <= ? GROUP BY v.doc""", (start, end)))
    times = []
    runs = []
    for frame_id, stamp in records:
        bucket = buckets[min(len(buckets) - 1, int((stamp - start) // interval))]
        bucket["frames"] += 1
        bucket["word_total"] += words.get(frame_id, 0)
        times.append(stamp)
        if not runs or stamp - runs[-1]["end"] > 60:
            runs.append({"start": stamp, "end": stamp, "frames": 1})
        else:
            runs[-1]["end"] = stamp
            runs[-1]["frames"] += 1
    for bucket in buckets:
        bucket["words_per_frame"] = round(bucket.pop("word_total") / bucket["frames"], 1) if bucket["frames"] else None

    # Gaps mean no saved changes, not confirmed downtime.
    gaps = [{"start": a, "end": b, "seconds": b - a}
            for a, b in zip([start] + times, times + [end]) if b - a >= 300]
    gaps.sort(key=lambda gap: gap["seconds"], reverse=True)
    latest_age = None if last is None else max(0, now - last)
    return {
        "from": start, "to": end, "checked_at": now,
        "latest_capture": last, "latest_age_seconds": latest_age,
        "frames": len(records), "interval_seconds": interval, "buckets": buckets,
        "gaps": gaps[:5],
        "capture_runs": runs,
        "word_metric": "Distinct indexed words per saved frame; repeated words count once.",
    }


def time_axis(start, end, width):
    """Seven evenly spaced ticks; labels are centered on the cells they describe."""
    labels = [" "] * width
    ticks = ["─"] * width
    show_seconds = end - start < 3600 or start % 60 != 0
    fmt = "%d %Hh" if end - start > 86400 else "%H:%M:%S" if show_seconds else "%H:%M"
    for i in range(7):
        position = round(i * (width - 1) / 6)
        stamp = start + (end - start) * i / 6
        label = datetime.fromtimestamp(stamp).strftime(fmt)
        # Distribute label boxes so second labels do not collide at either edge.
        left = round(i * (width - len(label)) / 6)
        labels[left:left + len(label)] = label
        ticks[position] = "┬"
    return "".join(ticks), "".join(labels)


def cell_duration(seconds):
    if seconds < 60:
        return f"{seconds:.1f}".rstrip("0").rstrip(".") + "s"
    return f"{seconds / 60:.1f}".rstrip("0").rstrip(".") + "m"


def render(data, service, color=False, live=False, interactive=False):
    def paint(text, code):
        return f"\033[{code}m{text}\033[0m" if color else text

    def dated(stamp):
        return datetime.fromtimestamp(stamp).strftime("%a %d %b %H:%M")

    age = data["latest_age_seconds"]
    if service in ("stopped", "not loaded"):
        status, code = "RECORDER STOPPED", "31"
    elif age is None:
        status, code = "NO SAVED FRAMES", "33"
    elif age <= 30:
        status, code = "RECENT CAPTURES", "32"
    else:
        status, code = "NO RECENT CAPTURES", "33"
    lines = [
        "Mac screen capture history",
        paint(status, code) + f"  ·  recorder {service}",
        "Last saved: " + ("never" if age is None else
                          f"{dated(data['latest_capture'])} ({duration(age)} ago)"),
        f"{'LIVE' if live else 'HISTORY'} · {duration(data['to'] - data['from'])} window"
        f" · {data['frames']:,} frames",
        f"{dated(data['from'])} → {dated(data['to'])}",
        "",
    ]
    buckets = data["buckets"]
    counts = [b["frames"] for b in buckets]
    maximum = max(counts, default=0)
    levels = "▁▂▃▄▅▆▇█"
    activity = "".join(paint(levels[max(0, math.ceil(n / maximum * 8) - 1)], "32")
                       if n else paint("·", "90") for n in counts)
    values = [b["words_per_frame"] for b in buckets]
    peak = max((v for v in values if v is not None), default=0)
    words = "".join("·" if v is None else levels[round(v / peak * 7)] if peak else "▁" for v in values)
    ticks, labels = time_axis(data["from"], data["to"], len(buckets))
    lines += [
        "Frames " + activity,
        "Words  " + paint(words, "36"),
        "       " + ticks,
        "       " + labels,
        f"Each cell = {cell_duration(data['interval_seconds'])}. · no saved frames; ▁–█ fewer–more.",
        f"Peaks: {maximum} frames/cell · {peak:g} unique words/frame (cell average).",
        "",
    ]
    lines.append("Recent captures (a new group starts after a gap over 1 minute):")
    for run in data["capture_runs"][-4:]:
        fmt = "%d %b %H:%M:%S" if data["to"] - data["from"] > 86400 else "%H:%M:%S"
        a, b = (datetime.fromtimestamp(run[k]).strftime(fmt) for k in ("start", "end"))
        lines.append(f"  {a}–{b}  {run['frames']:,} frames")
    if not data["capture_runs"]:
        lines.append("  No captures in this window.")
    lines += ["", "Gaps may be idle/locked screens or failures; not an uptime percentage."]
    if interactive:
        lines += ["", "+/− zoom  ←/→ move through time  L live  Q quit  ·  refresh 5s"]
    return "\n".join(lines)


@dataclass
class View:
    span: float = 3600
    anchor: float | None = None

    def window(self, now):
        # Stable minute boundaries avoid a chart that slides each refresh.
        step = 60 if self.span >= 3600 else 10 if self.span >= 300 else 1
        end = self.anchor if self.anchor is not None else math.ceil(now / step) * step
        return end - self.span, end

    def key(self, key, now):
        if key in ("q", "Q", "\x03"):
            return False
        if key in ("+", "="):
            self.span = max((s for s in ZOOM_SPANS if s < self.span), default=ZOOM_SPANS[0])
        elif key in ("-", "_"):
            self.span = min((s for s in ZOOM_SPANS if s > self.span), default=ZOOM_SPANS[-1])
        elif key in ("\x1b[D", "h"):
            self.anchor = self.window(now)[1] - self.span / 2
        elif key in ("\x1b[C", "l"):
            end = self.window(now)[1] + self.span / 2
            self.anchor = None if end >= now else end
        elif key == "L":
            self.anchor = None
        return True


@contextmanager
def terminal_input(enabled):
    if not enabled:
        yield
        return
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1049h\033[?25l")
        sys.stdout.flush()
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write("\033[?25h\033[?1049l")
        sys.stdout.flush()


def next_key(timeout):
    if not select.select([sys.stdin], [], [], timeout)[0]:
        return ""
    key = os.read(sys.stdin.fileno(), 1).decode()
    if not key:
        return "q"
    if key == "\x1b":
        # Arrow escape sequences may arrive in separate reads.
        for _ in range(2):
            if select.select([sys.stdin], [], [], .05)[0]:
                key += os.read(sys.stdin.fileno(), 1).decode()
    return key


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("from_time", nargs="?", default="1h", help="1h (default), today, 30m, 24h, HH:MM, or ISO timestamp")
    parser.add_argument("to_time", nargs="?", default="now")
    parser.add_argument("--history", type=Path, default=Path.home() / ".ascii-screen" / "history",
                        help="history directory (default: ~/.ascii-screen/history)")
    parser.add_argument("--json", action="store_true", help="emit bucket counts and timestamps as JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--watch", action="store_true", help="refresh every five seconds (default in a terminal)")
    mode.add_argument("--once", action="store_true", help="print once and exit")
    args = parser.parse_args(argv)
    if args.watch and args.json:
        parser.error("--watch and --json cannot be combined")
    now = time.time()
    try:
        start, end = parse_time(args.from_time, now), min(now, parse_time(args.to_time, now))
    except ValueError as exc:
        parser.error(f"invalid time: {exc}")
    if start >= end:
        parser.error("from must be earlier than to")
    view = View(end - start, None if args.to_time == "now" else end)
    watch = not args.once and not args.json and (args.watch or sys.stdout.isatty())
    interactive = watch and sys.stdin.isatty() and sys.stdout.isatty()
    try:
        with terminal_input(interactive):
            while True:
                now = time.time()
                start, end = view.window(now)
                # 60 cells makes the default hour one minute/cell.
                available = shutil.get_terminal_size().columns - 8
                width = max(60, min(180, available // 60 * 60))
                if view.span < 3600:
                    width = max(66, width)
                data = read_activity(args.history, start, end, now, width)
                data["service"] = service_status()
                if watch and sys.stdout.isatty():
                    print("\033[H\033[J", end="")
                print(json.dumps(data, indent=2) if args.json else
                      render(data, data["service"], sys.stdout.isatty(),
                             live=view.anchor is None, interactive=interactive), flush=True)
                if not watch:
                    return 0
                if interactive:
                    if not view.key(next_key(5), time.time()):
                        return 0
                else:
                    time.sleep(5)
    except (sqlite3.Error, OSError) as exc:
        print(f"Cannot read capture history: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
