// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation

/// Advances through cue boundaries during playback and rebuilds after a backward
/// seek. Offsets preserve file order, including overlapping cues and repeated IDs.
final class VividSubtitleCueCursor {
    struct Selection {
        let offsets: [Int]
        let cues: [SubtitleCue]
        static let empty = Selection(offsets: [], cues: [])
    }

    private let cues: [SubtitleCue]
    private let starts: [Int]
    private let ends: [Int]
    private var nextStart = 0
    private var nextEnd = 0
    private var lastTime: Double?
    private var active: Set<Int> = []
    private var selection = Selection.empty

    init(_ cues: [SubtitleCue]) {
        self.cues = cues
        let valid = cues.indices.filter { cues[$0].startTime < cues[$0].endTime }
        starts = valid.sorted { cues[$0].startTime < cues[$1].startTime }
        ends = valid.sorted { cues[$0].endTime < cues[$1].endTime }
    }

    func selection(at time: Double) -> Selection {
        guard !time.isNaN else {
            lastTime = nil
            active.removeAll(keepingCapacity: true)
            selection = .empty
            return selection
        }
        if let lastTime, time >= lastTime {
            // Most clock updates cross no cue boundary and need no scan,
            // allocation, sorting or publication.
            if (nextStart == starts.count || cues[starts[nextStart]].startTime > time),
               (nextEnd == ends.count || cues[ends[nextEnd]].endTime > time) {
                self.lastTime = time
                return selection
            }
            while nextStart < starts.count, cues[starts[nextStart]].startTime <= time {
                let offset = starts[nextStart]
                if time < cues[offset].endTime { active.insert(offset) }
                nextStart += 1
            }
            while nextEnd < ends.count, cues[ends[nextEnd]].endTime <= time {
                active.remove(ends[nextEnd])
                nextEnd += 1
            }
        } else {
            nextStart = upperBound(starts, at: time, key: \.startTime)
            nextEnd = upperBound(ends, at: time, key: \.endTime)
            active = Set(starts[..<nextStart].filter { time < cues[$0].endTime })
        }
        lastTime = time
        let offsets = active.sorted()
        if offsets != selection.offsets {
            selection = Selection(offsets: offsets, cues: offsets.map { cues[$0] })
        }
        return selection
    }

    private func upperBound(_ offsets: [Int], at time: Double,
                            key: KeyPath<SubtitleCue, Double>) -> Int {
        var lower = 0
        var upper = offsets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[offsets[middle]][keyPath: key] <= time { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}
