#!/usr/bin/env python3
"""Compile the patched clock's actual pure calculation and verify timestamp mapping."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("audio_engine_source", type=Path)
parser.add_argument("module_cache", type=Path)
args = parser.parse_args()
source = args.audio_engine_source.read_text()
clock = source.split("public enum KSAudioPresentationClock {", 1)[1].split("\npublic protocol AudioOutput:", 1)[0]
checks = r'''
var checks = 0
func expect(_ value: Double?, _ expected: Double) {
    precondition(value != nil && abs(value! - expected) < 0.000001)
    checks += 1
}
let map = KSAudioPresentationClock.mediaTime
// A buffer beginning at media time 100, rendered 20 ms ahead, with 2.085 s latency.
expect(map(100.032, 0.020, 1536, 48000, 2.085), 97.895)
// The same samples in differently sized callbacks must produce the same clock.
expect(map(100.016, 0.020, 768, 48000, 2.085), 97.895)
expect(map(100.010, 0.020, 441, 44100, 2.085), 97.895)
// A callback arriving late advances media time, rather than adding more delay.
expect(map(100.032, -0.010, 1536, 48000, 2.085), 97.925)
// No accumulating counter: elapsed time, seeks and timestamp discontinuities re-anchor.
for start in [0.0, 3.0, 100.0, 7200.0] {
    expect(map(start + 0.032, 0, 1536, 48000, 2), start - 2)
}
// Already combined device/processing latency is used once; no extra I/O buffer.
expect(map(100.032, 0, 1536, 48000, 0.080), 99.920)
for invalid in [Double.nan, Double.infinity, -Double.infinity] {
    precondition(map(invalid, 0, 1536, 48000, 2) == nil)
    precondition(map(100, invalid, 1536, 48000, 2) == nil)
    precondition(map(100, 0, 1536, invalid, 2) == nil)
    precondition(map(100, 0, 1536, 48000, invalid) == nil)
    checks += 4
}
precondition(map(100, 0, 0, 48000, 2) == nil)
precondition(map(100, 0, 1536, 0, 2) == nil)
precondition(map(100, 0, 1536, -48000, 2) == nil)
precondition(map(100, 0, 1536, 48000, -1) == nil)
checks += 4
print("Passed \(checks) render-presentation mapping checks. Hardware sync remains unverified.")
'''
with tempfile.TemporaryDirectory(prefix="vivid-pcm-clock-") as temporary:
    root = Path(temporary)
    swift = root / "main.swift"
    swift.write_text("import Foundation\npublic enum KSAudioPresentationClock {" + clock + checks)
    executable = root / "checks"
    subprocess.run(["swiftc", "-module-cache-path", str(args.module_cache), str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
