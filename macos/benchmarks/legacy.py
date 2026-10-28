import json
from pathlib import Path
import resource
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
image = Path(sys.argv[1])
while True:
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    subprocess.run(["screencapture", "-x", str(image)], check=True)
    subprocess.run(["node", str(root / "index.js"), str(image)], check=True, stdout=subprocess.DEVNULL)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    print(json.dumps({
        "time": time.time(),
        "wall_seconds": time.monotonic() - started,
        "cpu_seconds": after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
    }), flush=True)
    time.sleep(1)
