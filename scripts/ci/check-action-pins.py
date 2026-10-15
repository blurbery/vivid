#!/usr/bin/env python3
"""Fail when a workflow uses an action or reusable workflow by tag or branch.

A tag such as @v4 can be moved to different code after review. Every `uses:`
in .github/workflows/ that names another repository's action or reusable
workflow must name a full commit SHA. Put the version it was taken from in a
trailing comment, for example:

    uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

Dependabot updates the SHA and the comment together. Local actions (./...)
and docker:// images are not checked, nor is text inside block scalars such
as run: | or script: |; a key called uses: anywhere else is checked. Run with
no arguments.
"""
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
# uses: in a step or at job level, quoted, or anywhere in a flow mapping
# ({ name: x, uses: ... }).
USES = re.compile(r"""(?:^\s*(?:-\s*)?|[{,]\s*)["']?uses["']?\s*:(?:\s+|$)["']?([^"'\s#,}\]]*)""")
PINNED = re.compile(r"@[0-9a-f]{40}$")
# A key whose value is a block scalar, such as run: | or run: >-2.
BLOCK = re.compile(r"^(\s*(?:-\s*)?)[\w-]+:\s*[|>](?:[1-9][-+]?|[-+][1-9]?)?\s*(?:#.*)?$")


def problems_in(text):
    """(line number, message) for each unpinned uses: outside run: blocks."""
    found = []
    block_indent = None
    for number, line in enumerate(text.splitlines(), 1):
        indent = len(line) - len(line.lstrip())
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        uses = list(USES.finditer(line))
        if not uses:
            block = BLOCK.match(line)
            if block:
                block_indent = len(block[1])
            continue
        for match in uses:
            action = match[1]
            if not action or action[0] in "|>":
                found.append((number, "uses: has no action on the same line. Put the action and its SHA on the uses: line."))
            elif action.startswith(("./", "docker://")):
                continue
            elif not PINNED.search(action):
                found.append((number, f"{action} is not pinned to a commit SHA. Use the full SHA, with the version in a trailing comment."))
    return found


def main():
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    failed = False
    for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        path = workflow.relative_to(ROOT).as_posix()
        for number, message in problems_in(workflow.read_text(encoding="utf-8", errors="replace")):
            failed = True
            print(f"::error file={path},line={number},title=Action pins::{message}" if annotate else f"{path}:{number}: {message}")
    if failed:
        return 1
    print("Every workflow action is pinned to a commit SHA.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
