#!/usr/bin/env python3
"""Summarise source-free PlaybackTrial logs. Missing pictures never become ready times."""
import argparse
import json
import re
import sys
import unittest


def summarise(lines):
    sessions = {}
    for line in lines:
        match = re.search(r"trial session=([\w-]+) event=(\w+)(.*)", line)
        if not match:
            continue
        identifier, event, rest = match.groups()
        fields = dict(re.findall(r"(\w+)=([^\s]+)", rest))
        session = sessions.setdefault(identifier, {
            "session": identifier, "origin": "unknown", "milestones_ms": {},
            "seek_picture_ms": [], "stalls": 0, "failed": False,
            "first_picture_ms": None,
        })
        if event == "start":
            session["origin"] = fields.get("origin", "unknown")
        elapsed = fields.get("elapsed_ms")
        if elapsed and elapsed.isdecimal():
            value = int(elapsed)
            if event == "seek_picture_ready":
                session["seek_picture_ms"].append(value)
            else:
                session["milestones_ms"].setdefault(event, value)
                if event == "first_picture_ready":
                    session["first_picture_ms"] = session["milestones_ms"][event]
        stalls = fields.get("stalls")
        if stalls and stalls.isdecimal():
            session["stalls"] = max(session["stalls"], int(stalls))
        if event == "failed":
            session["failed"] = True
    return list(sessions.values())


class TraceTests(unittest.TestCase):
    def test_ready_is_not_a_picture(self):
        rows = summarise([
            "trial session=a event=start origin=play_request",
            "trial session=a event=player_ready elapsed_ms=90",
            "trial session=a event=playing elapsed_ms=100",
        ])
        self.assertIsNone(rows[0]["first_picture_ms"])

    def test_seeks_and_reloads_do_not_replace_startup(self):
        rows = summarise([
            "trial session=a event=start origin=play_request",
            "trial session=a event=first_picture_ready elapsed_ms=800",
            "trial session=a event=seek_picture_ready seek=1 elapsed_ms=240",
            "trial session=a event=stall stalls=1",
            "trial session=a event=sample stalls=1",
            "trial session=b event=start origin=engine_load",
            "trial session=b event=failed code=1",
        ])
        self.assertEqual(rows[0]["first_picture_ms"], 800)
        self.assertEqual(rows[0]["seek_picture_ms"], [240])
        self.assertEqual(rows[0]["stalls"], 1)
        self.assertEqual(rows[1]["origin"], "engine_load")
        self.assertTrue(rows[1]["failed"])
        self.assertIsNone(rows[1]["first_picture_ms"])

    def test_metal_submission_is_not_presentation(self):
        rows = summarise(["trial session=a event=metal_frame_submitted elapsed_ms=300"])
        self.assertIsNone(rows[0]["first_picture_ms"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", help="Exported PlaybackTrial log files, or - for stdin")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(TraceTests))
        return 0 if result.wasSuccessful() else 1
    if not args.logs:
        parser.error("supply a log file or - for stdin")

    def lines():
        for path in args.logs:
            if path == "-":
                yield from sys.stdin
            else:
                with open(path, encoding="utf-8", errors="replace") as stream:
                    yield from stream

    json.dump(summarise(lines()), sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
