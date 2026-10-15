#!/usr/bin/env python3
"""Fail when a workflow uses an action or reusable workflow by tag or branch.

A tag such as @v4 can be moved to different code after review. Every `uses:`
that names another repository's action or reusable workflow must name a full
commit SHA, with the version it was taken from in a trailing comment, for
example:

    uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

Dependabot updates the SHA and the comment together. Local actions (./...)
and docker:// images are not checked.

Each workflow in .github/workflows/ is parsed as YAML with Ruby's YAML
library, which GitHub's Ubuntu and macOS runners include, so quoting, flow
mappings, explicit keys and block scalars are read exactly as GitHub reads
them. The places GitHub takes an action from are checked: jobs.<id>.uses (a
reusable workflow) and jobs.<id>.steps[*].uses. YAML drops comments, so the
version comment is checked on each line of the file that holds a pinned
value. Run with no arguments.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PINNED = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
TO_JSON = "require 'yaml'; require 'json'; puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true) || {})"


def parse(text):
    """The workflow as plain data, parsed by Ruby's YAML library."""
    result = subprocess.run(["ruby", "-e", TO_JSON], input=text, capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError(result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "not valid YAML")
    return json.loads(result.stdout)


def uses_values(workflow):
    """(where, value) for every uses: GitHub reads in a parsed workflow."""
    found = []
    jobs = workflow.get("jobs") if isinstance(workflow, dict) else None
    for job_id, job in (jobs or {}).items():
        if not isinstance(job, dict):
            continue
        if "uses" in job:
            found.append((f"jobs.{job_id}.uses", job["uses"]))
        for index, step in enumerate(job.get("steps") or []):
            if isinstance(step, dict) and "uses" in step:
                found.append((f"jobs.{job_id}.steps[{index}].uses", step["uses"]))
    return found


def line_of(lines, value):
    """The first line number holding value, or None."""
    return next((number for number, line in enumerate(lines, 1) if value in line), None)


def problems_in(text):
    """(line number or None, message) for each uses: that isn't pinned with a version comment."""
    try:
        workflow = parse(text)
    except ValueError as error:
        return [(None, f"The workflow couldn't be read as YAML: {error}")]
    lines = text.splitlines()
    problems = []
    pinned = set()
    for where, value in uses_values(workflow):
        if not isinstance(value, str) or not value.strip():
            problems.append((None, f"{where} has no action."))
            continue
        action = value.strip()
        if action.startswith(("./", "docker://")):
            continue
        if PINNED.match(action):
            pinned.add(action)
        else:
            problems.append((line_of(lines, action), f"{action} ({where}) is not pinned to a commit SHA. "
                                                     "Use the full SHA, with the version in a trailing comment."))
    for action in sorted(pinned):
        for number, line in enumerate(lines, 1):
            at = line.find(action)
            if at >= 0 and not re.search(r"\s#\s*\S", line[at + len(action):]):
                problems.append((number, f"{action} has no version comment. "
                                         "Add the version it was taken from, for example # v4."))
    return sorted(problems, key=lambda problem: (problem[0] or 0, problem[1]))


def main():
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    failed = False
    for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        path = workflow.relative_to(ROOT).as_posix()
        for number, message in problems_in(workflow.read_text(encoding="utf-8", errors="replace")):
            failed = True
            if annotate:
                location = f"file={path},line={number}" if number else f"file={path}"
                print(f"::error {location},title=Action pins::{message}")
            else:
                print(f"{path}:{number or 1}: {message}")
    if failed:
        return 1
    print("Every workflow action is pinned to a commit SHA with a version comment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
