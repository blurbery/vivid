#!/bin/bash
# Checks the Siri Remote timeline maths the Apple TV scrubber uses: the swipe
# deadzone and distance, the Left and Right steps and the hold-to-seek rate
# ladder. The script keeps its old name, but circular "wheel" seeking was
# removed so it wouldn't compete with horizontal swipes (see
# docs/playback/README.md); swipes are what it tests now.
set -euo pipefail
cd "$(dirname "$0")/../.."
source_file=iosApp/iosApp/Screens/Player/tvOS/TVPlayerScrubber.swift
wheel_tmp=$(mktemp -d /private/tmp/vivid-wheel-check.XXXXXX)
trap 'rm -rf "$wheel_tmp"' EXIT
block=$(sed -n '/^\/\/ BEGIN TVTimelineScrubMath$/,/^\/\/ END TVTimelineScrubMath$/p' "$source_file")
if [ -z "$block" ]; then
    echo "error: no TVTimelineScrubMath block in $source_file" >&2
    exit 1
fi
{
    echo 'import Foundation'
    printf '%s\n' "$block"
    cat <<'SWIFT'
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }

// Replays one drag the way TVPlayerScrubber does: deltas build up until they
// cross the deadzone, then move the preview from wherever it is.
func drag(_ deltas: [CGFloat], from start: Double, duration: Double) -> Double {
    var tracker = TVTimelinePanTracker()
    var time = start
    for delta in deltas {
        guard let translation = tracker.translation(for: delta) else { continue }
        let seconds = TVTimelineScrubMath.panSeconds(forTranslation: translation, duration: duration)
        time = TVTimelineScrubMath.clampedTime(time + seconds, duration: duration)
    }
    return time
}

// Swipes
precondition(drag([3, -2, 4, 2], from: 600, duration: 3600) == 600, "Click jitter inside the deadzone must not move the preview")
precondition(drag([-5, -6.9], from: 600, duration: 3600) == 600, "Jitter just inside the deadzone must not move the preview")
precondition(near(drag([6, 6], from: 600, duration: 3600), 600 + 12.0 / 12000 * 3600), "Crossing the deadzone applies the whole build-up")
precondition(near(drag([-12], from: 600, duration: 3600), 600 - 12.0 / 12000 * 3600), "Leftward drags cross the deadzone too")
precondition(near(drag([12, 1, 1], from: 600, duration: 3600), 600 + 14.0 / 12000 * 3600), "Once engaged, every delta moves the preview")
precondition(near(drag([12, -0.5], from: 600, duration: 3600), 600 + 11.5 / 12000 * 3600), "Once engaged, small deltas are not filtered")
precondition(near(drag(Array(repeating: 100, count: 120), from: 0, duration: 3600), 3600), "12,000 points of drag covers the whole timeline")
precondition(near(drag(Array(repeating: 100, count: 10), from: 0, duration: 7200), 600), "A 1,000 point swipe covers 1/12 of the timeline")
precondition(drag([5000, 5000, 5000], from: 3500, duration: 3600) == 3600, "A drag stops at the end")
precondition(drag([-5000, -5000], from: 100, duration: 3600) == 0, "A drag stops at the start")
var tracker = TVTimelinePanTracker()
precondition(tracker.translation(for: 20) == 20 && tracker.isEngaged, "A large first delta applies at once")
tracker = TVTimelinePanTracker()
precondition(!tracker.isEngaged && tracker.translation(for: 11) == nil, "A new drag starts inside the deadzone")

// Steps
precondition(TVTimelineScrubMath.backwardStep == 10 && TVTimelineScrubMath.forwardStep == 30, "Left steps back 10 seconds and Right forward 30")
precondition(TVTimelineScrubMath.clampedTime(5 - 10, duration: 3600) == 0, "Steps stop at the start")
precondition(TVTimelineScrubMath.clampedTime(3590 + 30, duration: 3600) == 3600, "Steps stop at the end")
precondition(TVTimelineScrubMath.fraction(of: 900, duration: 3600) == 0.25, "Fractions follow the duration")
precondition(TVTimelineScrubMath.fraction(of: 900, duration: 0) == 0, "No duration shows no progress")
precondition(TVTimelineScrubMath.fraction(of: 4000, duration: 3600) == 1, "Progress stops at the end")
precondition(TVTimelineScrubMath.fraction(of: -5, duration: 3600) == 0, "Progress stops at the start")

// Hold to seek
precondition(TVTimelineScrubMath.autoSeekBaseStep == 2, "Each 100 ms tick seeks 2 seconds times the rate")
precondition(TVTimelineScrubMath.autoSeekRate(from: 1, delta: 1) == 2, "Right speeds up a forward seek")
precondition(TVTimelineScrubMath.autoSeekRate(from: 1, delta: -1) == -1, "Left from 1x reverses without stopping at 0")
precondition(TVTimelineScrubMath.autoSeekRate(from: -1, delta: 1) == 1, "Right from -1x reverses without stopping at 0")
precondition(TVTimelineScrubMath.autoSeekRate(from: 32, delta: 1) == 32, "The ladder stops at 32x")
precondition(TVTimelineScrubMath.autoSeekRate(from: -32, delta: -1) == -32, "The ladder stops at -32x")
precondition(TVTimelineScrubMath.autoSeekRate(from: 0, delta: 1) == nil, "A rate off the ladder doesn't change")
precondition(TVTimelineScrubMath.autoSeekRate(from: 3, delta: 1) == nil, "A rate off the ladder doesn't change")

// The same inputs through the maths TVPlayerScrubber used before it moved
// into TVTimelineScrubMath must give the same answers.
func previousDrag(_ deltas: [CGFloat], from start: Double, duration: Double) -> Double {
    var engaged = false
    var accumulated: CGFloat = 0
    var time = start
    for deltaX in deltas {
        var translation = deltaX
        if !engaged {
            accumulated += deltaX
            guard abs(accumulated) >= 12 else { continue }
            engaged = true
            translation = accumulated
        }
        let deltaSeconds = Double(translation / 12000) * duration
        time = min(max(time + deltaSeconds, 0), duration)
    }
    return time
}
func previousRate(_ rate: Int, _ delta: Int) -> Int? {
    let rates = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]
    guard let index = rates.firstIndex(of: rate) else { return nil }
    return rates[max(0, min(rates.count - 1, index + delta))]
}
var seed: UInt64 = 0x5eed
func random(_ range: ClosedRange<Double>) -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return range.lowerBound + Double(seed >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
}
for _ in 0..<2000 {
    let duration = random(1...14_400)
    let start = random(0...duration)
    let deltas = (0..<Int(random(1...40))).map { _ in CGFloat(random(-400...400) * random(0...1) * random(0...1)) }
    precondition(drag(deltas, from: start, duration: duration) == previousDrag(deltas, from: start, duration: duration), "Swipe maths changed")
    let base = random(-100...15_000)
    for delta in [-10.0, 30.0, -64.0, 64.0] {
        precondition(TVTimelineScrubMath.clampedTime(base + delta, duration: duration) == min(max(base + delta, 0), duration), "Step maths changed")
    }
    precondition(TVTimelineScrubMath.fraction(of: base, duration: duration) == min(max(base / duration, 0), 1), "Progress maths changed")
}
for rate in -40...40 {
    for delta in [-2, -1, 1, 2] {
        precondition(TVTimelineScrubMath.autoSeekRate(from: rate, delta: delta) == previousRate(rate, delta), "Rate ladder changed")
    }
}
print("Remote timeline checks passed: swipe deadzone and distance, clamping, steps, the rate ladder, and agreement with the previous maths.")
SWIFT
} > "$wheel_tmp/check.swift"
xcrun swiftc "$wheel_tmp/check.swift" -o "$wheel_tmp/check"
"$wheel_tmp/check"
