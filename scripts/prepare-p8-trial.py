#!/usr/bin/env python3
"""Apply the small P8 metadata hook to the retained, exactly pinned KSPlayer checkout."""
import argparse
import difflib
from pathlib import Path
import subprocess

PIN = "7862a2b175b50db71135e57fd144ea0e441d47d6"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    patch = Path(__file__).resolve().parent / "patches/ksplayer-p8-format-hook.patch"

    def git(*arguments, check=True):
        return subprocess.run(["git", "-C", str(checkout), *arguments],
                              capture_output=True, text=True, check=check)

    if git("rev-parse", "HEAD").stdout.strip() != PIN:
        raise SystemExit("Refusing to patch a different KSPlayer revision.")
    if git("apply", "--reverse", "--check", str(patch), check=False).returncode == 0:
        files = ["Sources/KSPlayer/AVPlayer/KSOptions.swift",
                 "Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift"]
        actual = "".join("".join(difflib.unified_diff(
            git("show", "HEAD:" + name).stdout.splitlines(True),
            (checkout / name).read_text().splitlines(True),
            fromfile="a/" + name, tofile="b/" + name)) for name in files)
        status = set(git("status", "--porcelain").stdout.splitlines())
        if actual != patch.read_text() or status != {" M " + name for name in files}:
            raise SystemExit("Refusing an already patched checkout with unrelated local changes.")
        print("P8 metadata hook is already applied.")
        return
    if git("status", "--porcelain").stdout.strip():
        raise SystemExit("Refusing to overwrite local KSPlayer changes.")
    git("apply", "--check", str(patch))
    git("apply", str(patch))
    print("P8 metadata hook applied. Build the trial with VIVID_P8_TRIAL defined.")


if __name__ == "__main__":
    main()
