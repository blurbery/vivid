import Foundation

struct VividAirPlayRecovery {
    private(set) var pendingFlush = false

    mutating func recordFlush() { pendingFlush = true }
    mutating func takeFlush() -> Bool {
        let pending = pendingFlush
        pendingFlush = false
        return pending
    }

    static func audioAdvanced(from baseline: Double?, end: Double?, clock: Double,
                              finished: Bool) -> Bool {
        guard let end, end.isFinite, clock.isFinite else { return false }
        if finished { return end > clock }
        guard let baseline, baseline.isFinite else { return false }
        return end > baseline + 0.1 && end > clock + 0.04
    }
}
