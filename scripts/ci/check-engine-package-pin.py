#!/usr/bin/env python3
"""Check that both apps link Lucid Engine from blurbery/lucid-engine.

Both platform specs must pin the LucidEngine package to the same revision of
https://github.com/blurbery/lucid-engine and depend on its LucidEngine
product. Every tracked Package.resolved must pin lucid-engine at that
revision and contain no entry for the previous engine packages.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPECS = ["iosApp/project-ios.yml", "iosApp/project.yml"]
PACKAGE_URL = "https://github.com/blurbery/lucid-engine"
PACKAGE_IDENTITY = "lucid-engine"
# Split so that check-no-previous-player-code.py does not match this file.
FORBIDDEN = ["edde" "746", "mpv" "-build", "mpv" "kit", "ksplayer", "ffmpegkit", "ffmpegbuild", "vividkit"]

errors = []


def fail(message):
    errors.append(message)
    print(f"::error::{message}")


def normalise(url):
    url = url.strip().lower().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def spec_packages(text):
    """Returns {name: {key: value}} for the top-level `packages:` mapping."""
    packages, current, inside = {}, None, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            inside = line.rstrip() == "packages:"
            current = None
            continue
        if not inside:
            continue
        match = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
        if match:
            current = packages.setdefault(match.group(1), {})
            continue
        match = re.match(r"^    ([A-Za-z]+):\s*(\S+)\s*$", line)
        if match and current is not None:
            current[match.group(1)] = match.group(2).strip("'\"")
    return packages


revisions = {}
for spec in SPECS:
    text = (ROOT / spec).read_text()
    packages = spec_packages(text)
    engine = packages.get("LucidEngine")
    if engine is None:
        fail(f"{spec}: no LucidEngine package")
        continue
    if normalise(engine.get("url", "")) != PACKAGE_URL:
        fail(f"{spec}: LucidEngine url is {engine.get('url')!r}, expected {PACKAGE_URL}")
    revision = engine.get("revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        fail(f"{spec}: LucidEngine must be pinned by a full commit `revision:`, found {revision!r}")
    revisions[spec] = revision
    if not re.search(r"- package: LucidEngine\n\s+product: LucidEngine\n", text):
        fail(f"{spec}: no dependency on the LucidEngine product")
    for name, entry in packages.items():
        described = " ".join([name] + list(entry.values())).lower()
        for word in FORBIDDEN:
            if word in described:
                fail(f"{spec}: package {name} refers to {word}")

if len(set(revisions.values())) > 1:
    fail(f"the platform specs pin different revisions: {revisions}")
revision = next(iter(revisions.values()), "")

listed = subprocess.run(
    ["git", "ls-files", "--", "*Package.resolved"],
    cwd=ROOT, check=True, capture_output=True, text=True,
).stdout.split()
if not listed:
    fail("no tracked Package.resolved")
for resolved in listed:
    text = (ROOT / resolved).read_text()
    lowered = text.lower()
    for word in FORBIDDEN:
        if word in lowered:
            fail(f"{resolved}: contains {word}")
    data = json.loads(text)
    pins = data.get("pins") or data.get("object", {}).get("pins") or []
    engine = [
        pin for pin in pins
        if (pin.get("identity") or pin.get("package", "")).lower() == PACKAGE_IDENTITY
        or normalise(pin.get("location") or pin.get("repositoryURL") or "") == PACKAGE_URL
    ]
    if len(engine) != 1:
        fail(f"{resolved}: expected one lucid-engine pin, found {len(engine)}")
        continue
    pin = engine[0]
    location = normalise(pin.get("location") or pin.get("repositoryURL") or "")
    if location != PACKAGE_URL:
        fail(f"{resolved}: lucid-engine location is {location!r}, expected {PACKAGE_URL}")
    pinned = pin.get("state", {}).get("revision")
    if pinned != revision:
        fail(f"{resolved}: lucid-engine is pinned at {pinned}, the specs at {revision}")
    else:
        print(f"{resolved}: lucid-engine at {pinned}")

if errors:
    sys.exit(1)
print(f"Both specs and every Package.resolved pin {PACKAGE_URL} at {revision}.")
