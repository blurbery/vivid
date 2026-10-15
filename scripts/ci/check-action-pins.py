#!/usr/bin/env python3
"""Fail when a workflow uses an action or reusable workflow by tag or branch.

A tag such as @v4 can be moved to different code after review. Every `uses:`
in .github/workflows/ that names another repository's action or reusable
workflow must name a full commit SHA, with the version it was taken from in a
trailing comment, for example:

    uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

Dependabot updates the SHA and the comment together. Local actions (./...)
and docker:// images are not checked, nor is text inside block scalars such
as run: | or script: |. The workflow is read line by line rather than parsed:
uses: is found as a block key, as an explicit key (? uses), or as a key in a
flow mapping ({ name: x, uses: ... }), skipping quoted text. A key called
uses: anywhere else is checked too, which fails safe. Run with no arguments.
"""
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
# uses: at the start of a line or a step, optionally quoted.
BLOCK_USES = re.compile(r"""^\s*(?:-\s*)?["']?uses["']?\s*:(?:\s+|$)""")
# uses: as a key inside a flow mapping, after { or a comma.
FLOW_USES = re.compile(r"""\s*["']?uses["']?\s*:(?:\s+|$)""")
# An explicit key: "? uses", whose value follows on a ": value" line.
EXPLICIT_KEY = re.compile(r"""^\s*(?:-\s*)?\?\s*["']?uses["']?\s*$""")
EXPLICIT_VALUE = re.compile(r"""^\s*:(?:\s+|$)""")
PINNED = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
VERSION_COMMENT = re.compile(r"\s#\s*\S")
# A key whose value is a block scalar, such as run: | or run: >-2.
BLOCK = re.compile(r"^(\s*(?:-\s*)?)[\w-]+:\s*[|>](?:[1-9][-+]?|[-+][1-9]?)?\s*(?:#.*)?$")


def value_at(line, start):
    """The scalar starting at start: quoted or plain, ending at a comment, comma or brace."""
    rest = line[start:]
    if rest[:1] in ("'", '"'):
        end = rest.find(rest[0], 1)
        return rest[1:end] if end > 0 else rest[1:]
    return re.match(r"[^\s#,}\]]*", rest)[0]


def uses_values(line):
    """(position, value) for each uses: key on the line, ignoring quoted text."""
    found = []
    block = BLOCK_USES.match(line)
    if block:
        found.append((block.end(), value_at(line, block.end())))
    quote = None
    index = 0
    while index < len(line):
        char = line[index]
        if quote:
            if char == "\\" and quote == '"':
                index += 2
                continue
            if char == quote:
                if quote == "'" and line[index + 1:index + 2] == "'":
                    # '' is an escaped quote inside a single-quoted scalar.
                    index += 2
                    continue
                quote = None
        elif char in ("'", '"') and line[:index].rstrip()[-1:] in ("", "{", ",", ":", "[", "?", "-"):
            # A quote only opens a scalar when it starts a value or key: at the
            # start of the line, or after {, ",", :, [, ? or a dash. One inside
            # a plain scalar, as in it's or the 'x, is just text.
            quote = char
        elif char == "#" and (index == 0 or line[index - 1].isspace()):
            break
        elif char in "{,":
            key = FLOW_USES.match(line, index + 1)
            if key:
                found.append((key.end(), value_at(line, key.end())))
        index += 1
    return found


def check_value(number, line, end, action, found):
    if not action or action[0] in "|>":
        found.append((number, "uses: has no action on the same line. Put the action and its SHA on the uses: line."))
    elif action.startswith(("./", "docker://")):
        return
    elif not PINNED.match(action):
        found.append((number, f"{action} is not pinned to a commit SHA. Use the full SHA, with the version in a trailing comment."))
    elif not VERSION_COMMENT.search(line[end:]):
        found.append((number, f"{action} has no version comment. Add the version it was taken from, for example # v4."))


def problems_in(text):
    """(line number, message) for each unpinned uses: outside block scalars."""
    found = []
    block_indent = None
    explicit = False
    for number, line in enumerate(text.splitlines(), 1):
        indent = len(line) - len(line.lstrip())
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        if explicit and line.strip():
            explicit = False
            value = EXPLICIT_VALUE.match(line)
            if value:
                check_value(number, line, value.end(), value_at(line, value.end()), found)
                continue
        if EXPLICIT_KEY.match(line):
            explicit = True
            continue
        values = uses_values(line)
        if not values:
            block = BLOCK.match(line)
            if block:
                block_indent = len(block[1])
            continue
        for start, action in values:
            end = start + len(action) + (2 if line[start:start + 1] in ("'", '"') else 0)
            check_value(number, line, end, action, found)
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
    print("Every workflow action is pinned to a commit SHA with a version comment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
