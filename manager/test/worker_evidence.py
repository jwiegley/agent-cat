#!/usr/bin/env python3
"""Inspect only deterministic fixture evidence, without signalling recorded PIDs."""
import json
from pathlib import Path
import subprocess
import sys

work = Path(sys.argv[1]).resolve()
native = str(Path(sys.argv[2]).resolve())
records = []
for path in work.glob("*.ndjson"):
    records.extend(json.loads(line) for line in path.read_text().splitlines())
if not records:
    raise RuntimeError("missing real configured-wrapper evidence")
for record in records:
    if record["cwd"] != str(work):
        raise RuntimeError("configured cwd changed")
    environment = record["env"]
    expected = {"XDG_CONFIG_HOME": str(work / "config"), "TMPDIR": str(work),
                "WORKER_EXPLICIT": "configured only", "LC_ALL": "C",
                "PYTHONCOERCECLOCALE": "0", "PYTHONUTF8": "1"}
    if any(environment.get(key) != value for key, value in expected.items()):
        raise RuntimeError("explicit environment changed")
    if "WM012_AMBIENT_SECRET" in environment:
        raise RuntimeError("ambient manager binding leaked")
    if record["args"] not in [["frontend"], ["frontend", "--capabilities"],
                               ["list", "--json", "--descriptor-version", "3"]]:
        raise RuntimeError("configured ordered prefix was not consumed exactly")
print("PASS real wrapper argv/cwd/explicit environment and ambient exclusion")

# Runtime remains the sole signalling/reaping owner. This is a read-only OS observation.
pids = {record["pid"] for record in records}
for path in work.glob("*.child"):
    pids.add(int(path.read_text()))
for pid in sorted(pids):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    if result.returncode == 0 and (str(work) in result.stdout or native in result.stdout):
        raise RuntimeError("owned fixture process still present after joined cleanup")
print("PASS recorded fixture processes absent after joined cleanup")
