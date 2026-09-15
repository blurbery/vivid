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
    for session in sessions.values():
        times = session["milestones_ms"]
        # Fixed boundaries remain comparable across runs. Missing endpoints stay missing.
        origin = "play_request" if session["origin"] == "play_request" else "engine_load"
        boundaries = [
            ("App preparation", origin, "source_open_begins"),
            ("Source open", "source_open_begins", "source_open_completed"),
            ("Probe and adjacent setup", "source_open_completed", "probe_completed"),
            ("Post-probe source setup", "probe_completed", "upstream_ready"),
            ("Main-thread wait and audio preparation", "upstream_ready", "ready_callback_begins"),
            ("Vivid ready callback", "ready_callback_begins", "ready_callback_completed"),
            ("Ready callback to picture", "ready_callback_completed", "first_picture_ready"),
            ("Decoded frame retrieval to picture", "first_decoded_video_retrieved", "first_picture_ready"),
            ("Display criteria call", "display_criteria_begins", "display_criteria_returned"),
        ]
        session["intervals_ms"] = {
            label: times[end] - times[start]
            if start in times and end in times and times[end] >= times[start] else None
            for label, start, end in boundaries
        }
        session["picture_measurement"] = "attached_layer_ready_not_physical_display"
    return list(sessions.values())


def text_report(sessions):
    blocks = []
    for session in sessions:
        lines = [f"Session {session['session']} (origin: {session['origin']})"]
        for event, elapsed in sorted(session["milestones_ms"].items(), key=lambda item: item[1]):
            lines.append(f"  {elapsed:>6} ms  {event}")
        lines.append("Intervals (overlapping observations, do not sum):")
        for label, elapsed in session["intervals_ms"].items():
            value = "unavailable" if elapsed is None else f"{elapsed} ms"
            lines.append(f"  {label}: {value}")
        picture = session["first_picture_ms"]
        label = "Play request" if session["origin"] == "play_request" else "Engine load"
        lines.append(f"{label} -> attached layer ready: " + ("unavailable" if picture is None else f"{picture} ms"))
        lines.append("Actual visible frame requires device observation; HDMI switching is not included.")
        lines.append(f"Seek-to-picture samples: {session['seek_picture_ms']}; stalls: {session['stalls']}; failed: {session['failed']}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


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

    def test_out_of_order_delivery_uses_captured_times(self):
        row = summarise([
            "trial session=a event=start origin=play_request",
            "trial session=a event=play_request elapsed_ms=0",
            "trial session=a event=source_open_completed elapsed_ms=250",
            "trial session=a event=source_open_begins elapsed_ms=100",
            "trial session=a event=probe_completed elapsed_ms=950",
        ])[0]
        self.assertEqual(row["intervals_ms"]["App preparation"], 100)
        self.assertEqual(row["intervals_ms"]["Source open"], 150)
        self.assertEqual(row["intervals_ms"]["Probe and adjacent setup"], 700)
        self.assertIsNone(row["intervals_ms"]["Ready callback to picture"])

    def test_early_picture_is_not_negative_startup_delay(self):
        row = summarise([
            "trial session=a event=first_picture_ready elapsed_ms=200",
            "trial session=a event=ready_callback_completed elapsed_ms=250",
        ])[0]
        self.assertIsNone(row["intervals_ms"]["Ready callback to picture"])
        self.assertEqual(row["first_picture_ms"], 200)

    def test_reload_report_does_not_claim_play_request_timing(self):
        report = text_report(summarise([
            "trial session=a event=start origin=engine_load",
            "trial session=a event=first_picture_ready elapsed_ms=900",
        ]))
        self.assertIn("Engine load -> attached layer ready: 900 ms", report)
        self.assertNotIn("Play request ->", report)

    def test_metal_submission_is_not_presentation(self):
        rows = summarise(["trial session=a event=metal_frame_submitted elapsed_ms=300"])
        self.assertIsNone(rows[0]["first_picture_ms"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", help="Exported PlaybackTrial log files, or - for stdin")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--text", action="store_true", help="Print a chronological startup trace and stage intervals")
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

    sessions = summarise(lines())
    if args.text:
        print(text_report(sessions))
    else:
        json.dump(sessions, sys.stdout, indent=2)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
