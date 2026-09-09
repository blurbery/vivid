import Foundation

struct VividHDMIAudioCore {
    enum Action: Equatable { case none, flushAudio, recovered, failed }
    private var stalledSince: TimeInterval?
    private var lastEnd: Double?
    private var lastClock: Double?
    private var recoveryStarted: TimeInterval?
    private var recoveryEnd: Double?
    private var attempted = false
    private var exhausted = false
    var isRecovering: Bool { recoveryStarted != nil }

    static func accepts(routeTypes: [String]) -> Bool {
        !routeTypes.isEmpty && routeTypes.allSatisfy { $0 == "HDMIOutput" }
    }

    static func catchUpFloor(recoveryFloor: Double?, clock: Double) -> Double? {
        guard let recoveryFloor, recoveryFloor.isFinite, clock.isFinite else { return nil }
        return max(recoveryFloor, clock)
    }

    mutating func suspend() {
        stalledSince = nil
        lastEnd = nil
        lastClock = nil
        recoveryStarted = nil
        recoveryEnd = nil
    }

    mutating func observe(clock: Double, audioEnd: Double?, ready: Bool,
                          uptime: TimeInterval, eligible: Bool, buffering: Bool = false,
                          sufficient: Bool = false) -> Action {
        guard !exhausted else { return .none }
        guard eligible, clock.isFinite, uptime.isFinite,
              let audioEnd, audioEnd.isFinite else {
            suspend()
            return .none
        }
        defer { lastEnd = audioEnd; lastClock = clock }
        if let recoveryStarted, let recoveryEnd {
            if audioEnd > recoveryEnd + 0.1 && audioEnd > clock + 0.04 {
                self.recoveryStarted = nil
                self.recoveryEnd = nil
                return .recovered
            }
            if uptime - recoveryStarted >= 6 {
                self.recoveryStarted = nil
                self.recoveryEnd = nil
                exhausted = true
                return .failed
            }
            return .none
        }
        guard !buffering, let lastClock, clock > lastClock,
              let lastEnd, abs(audioEnd - lastEnd) < 0.001,
              !ready, clock > audioEnd + 0.25 else {
            stalledSince = nil
            return .none
        }
        guard let stalledSince, uptime >= stalledSince else {
            stalledSince = uptime
            return .none
        }
        let stallTimeout: TimeInterval = sufficient && !attempted ? 0.5 : 6
        guard uptime - stalledSince >= stallTimeout else { return .none }
        if attempted {
            exhausted = true
            self.stalledSince = nil
            return .failed
        }
        attempted = true
        self.stalledSince = nil
        recoveryStarted = uptime
        recoveryEnd = audioEnd
        return .flushAudio
    }
}
