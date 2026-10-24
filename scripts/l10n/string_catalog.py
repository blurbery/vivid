#!/usr/bin/env python3
"""Switches Localizable.xcstrings entries between manual and extracted.

Used by sync-string-catalog.sh. `unmark` turns manual entries back into
extracted ones so `xcstringstool sync` can drop strings the code no longer
uses (and mark translated ones stale). `mark` makes every remaining entry
manual again, so the per-platform sync Xcode runs after an ordinary build
leaves the catalog alone. Stale entries stay stale in both directions.

The file is written the way Xcode writes it, so a catalog that hasn't changed
produces no diff.
"""
import json
import sys


def encode(value, depth=0):
    pad = "  " * (depth + 1)
    end = "  " * depth
    if isinstance(value, dict):
        items = [f"{pad}{encode(key)} : {encode(value[key], depth + 1)}" for key in sorted(value)]
        return "{\n" + ",\n".join(items) + "\n" + end + "}"
    if isinstance(value, list):
        items = [pad + encode(item, depth + 1) for item in value]
        return "[\n" + ",\n".join(items) + "\n" + end + "]"
    return json.dumps(value, ensure_ascii=False)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("mark", "unmark"):
        sys.exit("usage: string_catalog.py mark|unmark <catalog>")
    mode, path = sys.argv[1:]
    with open(path, encoding="utf-8") as file:
        catalog = json.load(file)
    for entry in catalog["strings"].values():
        state = entry.get("extractionState")
        if mode == "mark" and state != "stale":
            entry["extractionState"] = "manual"
        elif mode == "unmark" and state == "manual":
            del entry["extractionState"]
    with open(path, "w", encoding="utf-8") as file:
        file.write(encode(catalog))


if __name__ == "__main__":
    main()
