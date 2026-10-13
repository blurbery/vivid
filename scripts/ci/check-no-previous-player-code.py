#!/usr/bin/env python3
"""Check that no previous third-party player code or engine package returns.

Vivid's own player bridge and the Lucid Engine package replaced a bridge adapted
from a third-party project and a third-party engine package. This check fails
if any tracked file's path or contents names either of them, or the build
projects that package came from (case-insensitive). Git history is not checked.

The names are assembled from pieces, so this file does not match itself.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NAMES = ["edde" + "746", "ple" + "zy", "mpv" + "-build", "mpv" + "kit"]
PATTERN = "|".join(re.escape(name) for name in NAMES)

failures = []

paths = subprocess.run(
    ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True, text=True,
).stdout.split("\0")
for path in paths:
    if path and re.search(PATTERN, path, re.IGNORECASE):
        failures.append(f"{path}: the path names a previous player component")

# Binary files are searched too; git grep reports them without a line.
found = subprocess.run(
    ["git", "grep", "-n", "-i", "-E", PATTERN],
    cwd=ROOT, capture_output=True, text=True,
)
if found.returncode not in (0, 1):
    sys.exit(f"git grep failed: {found.stderr.strip()}")
for line in found.stdout.splitlines():
    failures.append(line[:300])

if failures:
    for failure in failures:
        print(f"::error::{failure}")
    print(f"{len(failures)} reference(s) to the previous player code or engine package.")
    sys.exit(1)
print("No tracked file names the previous player code or engine package.")
