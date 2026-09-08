#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
wheel_tmp=$(mktemp -d /private/tmp/vivid-wheel-check.XXXXXX)
trap 'rm -rf "$wheel_tmp"' EXIT
{
    echo 'import Foundation'
    sed -n '/^struct TVRemoteWheelTracker {/,/^#endif/p' iosApp/iosApp/Screens/Player/tvOS/TVPressCaptureView.swift | sed '$d'
    cat <<'SWIFT'
func revolution(direction: Double) -> Double {
    var tracker = TVRemoteWheelTracker()
    var total = 0.0
    for step in 0...120 {
        let angle = direction * Double(step) * 2 * Double.pi / 120
        total += tracker.update(x: cos(angle), y: sin(angle))
    }
    return total
}
precondition(abs(revolution(direction: -1) - 60) < 0.001, "Clockwise must seek forward across all quadrants")
precondition(abs(revolution(direction: 1) + 60) < 0.001, "Counterclockwise must seek backward across all quadrants")
var tracker = TVRemoteWheelTracker()
precondition(tracker.update(x: 1, y: 0) == 0, "First contact must not jump")
precondition(tracker.update(x: 0.99999, y: 0.00001) == 0, "Click jitter must not seek")
precondition(tracker.update(x: 0, y: 0) == 0, "Lift must reset")
precondition(tracker.update(x: -1, y: 0) == 0, "Repositioning after lift must not jump")
precondition(tracker.update(x: 0.1, y: 0.1) == 0, "Leaving the ring must not jump")
// Smaller and elliptical contacts used to enter linear mode and reverse
// direction halfway around. Test every delta, not just the net total.
for direction in [-1.0, 1.0] {
    for radius in [0.25, 0.5, 0.8] {
        var uneven = TVRemoteWheelTracker()
        var sum = 0.0
        for step in 0...240 {
            let angle = direction * Double(step) * 2 * Double.pi / 240
            let r = radius * (1 + 0.2 * sin(angle * 3))
            let delta = uneven.update(x: r * cos(angle), y: r * 0.8 * sin(angle))
            precondition(delta * direction <= 0, "Uneven circle must never reverse")
            sum += delta
        }
        precondition(abs(sum + direction * 60) < 0.001, "Uneven revolution should preserve angular distance")
    }
}
tracker = TVRemoteWheelTracker()
_ = tracker.update(x: 0.3, y: 0)
precondition(tracker.update(x: 0.8, y: 0) == 0, "Radial movement must not become horizontal seeking")
print("Remote wheel checks passed: directions, wrap, jitter, lift, small/uneven circles and radial movement.")
SWIFT
} > "$wheel_tmp/check.swift"
xcrun swiftc "$wheel_tmp/check.swift" -o "$wheel_tmp/check"
"$wheel_tmp/check"
