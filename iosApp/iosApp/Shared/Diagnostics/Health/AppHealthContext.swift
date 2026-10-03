#if os(iOS) || os(tvOS)
import Foundation
import os

/// What the app was doing, as enum-style tokens only. Attached to watchdog
/// hangs and unexpected exits so a report says whether it happened during
/// launch, browsing or playback. No titles, item IDs or hosts.
struct AppHealthContextSnapshot: Codable, Equatable {
    var phase: String = "launching"
    var playerOpen = false
    var playMethod: String?
    var memoryWarnings = 0
    var deviceOnline = true
    var serverReachable = true

    var attributes: [String: DiagnosticsJSONValue] {
        var attributes: [String: DiagnosticsJSONValue] = [
            "phase": .string(phase),
            "player_open": .bool(playerOpen),
            "memory_warnings": .int(memoryWarnings),
        ]
        if let playMethod { attributes["play_method"] = .string(playMethod) }
        if !deviceOnline { attributes["device_online"] = .bool(false) }
        if !serverReachable { attributes["server_reachable"] = .bool(false) }
        return attributes
    }

    /// Play methods come from the server (`DirectPlay`, `Transcode` and so
    /// on). Anything that is not a short word-like token is dropped.
    static func playMethodToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        guard !trimmed.isEmpty, trimmed.count <= 32,
              trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }
}

/// Written when the app becomes active and removed when it goes to the
/// background or terminates normally. Finding it on the next launch means the
/// app ended while in the foreground: a crash, a watchdog kill or a memory
/// termination.
struct AppHealthExitMarker: Codable, Equatable {
    let build: String
    let bootTime: Int
    let armedAt: Date
    let debuggerAttached: Bool
    /// Matches a MetricKit crash from the same process to this report.
    var pid: Int32?
    var context: AppHealthContextSnapshot
    /// Set while the watchdog sees the main thread stalled, so an exit during
    /// a long hang reads as a likely watchdog kill.
    var hangInProgressMs: Int?

    enum Verdict: Equatable {
        case none
        case discarded(reason: String)
        case unexpectedExit(AppHealthExitMarker)
    }

    /// Boot times are wall-clock derived and can shift by a moment when the
    /// clock is corrected, so allow a little slack. A restart takes far
    /// longer than this.
    static let bootTimeTolerance = 5

    static func evaluate(
        _ marker: AppHealthExitMarker?,
        currentBuild: String,
        currentBootTime: Int
    ) -> Verdict {
        guard let marker else { return .none }
        if marker.debuggerAttached { return .discarded(reason: "debugger") }
        // An update installs over the running app, ending it in place.
        if marker.build != currentBuild { return .discarded(reason: "build_changed") }
        // A restart, power cut or unplugged Apple TV is not an app fault.
        if abs(marker.bootTime - currentBootTime) > bootTimeTolerance {
            return .discarded(reason: "device_restarted")
        }
        return .unexpectedExit(marker)
    }

    /// An exit with no recorded signal: the system ended the app. The cause is
    /// a best guess from what the marker saw.
    func report(detectedAt: Date, app: AppHealthAppInfo, recentEvents: [String] = []) -> AppHealthReport {
        let cause: String
        if hangInProgressMs != nil {
            cause = "hang"
        } else if context.memoryWarnings > 0 {
            cause = "memory"
        } else {
            cause = "unknown"
        }
        var details: [String: DiagnosticsJSONValue] = [
            "likely_cause": .string(cause),
            "session_started": .string(ISO8601DateFormatter().string(from: armedAt)),
        ]
        if let hangInProgressMs { details["hang_in_progress_ms"] = .int(hangInProgressMs) }
        if let pid { details["pid"] = .int(Int(pid)) }
        return AppHealthReport(
            kind: .unexpectedExit,
            source: .exitMarker,
            recordedAt: detectedAt,
            app: app,
            details: details,
            context: context.attributes,
            recentEvents: recentEvents,
            fingerprintSeed: "\(build)|\(armedAt.timeIntervalSince1970)"
        )
    }

    /// A crash the signal handler saw. `marker` is nil when the app was in the
    /// background at the time, since the marker is cleared there.
    static func crashReport(
        _ crash: AppHealthCrashCapture.Previous,
        marker: AppHealthExitMarker?,
        backgroundContext: AppHealthBackgroundContext? = nil,
        detectedAt: Date,
        app: AppHealthAppInfo,
        recentEvents: [String] = []
    ) -> AppHealthReport {
        var details: [String: DiagnosticsJSONValue] = ["foreground": .bool(marker != nil)]
        if let pid = marker?.pid ?? backgroundContext?.pid { details["pid"] = .int(Int(pid)) }
        if let signal = crash.signal { details["signal"] = .int(Int(signal)) }
        if let name = crash.exceptionName { details["exception_name"] = .string(name) }
        if let reason = crash.exceptionReason, !reason.isEmpty { details["exception_message"] = .string(reason) }
        if let marker {
            details["session_started"] = .string(ISO8601DateFormatter().string(from: marker.armedAt))
        }
        return AppHealthReport(
            kind: .crash,
            source: .exitMarker,
            recordedAt: detectedAt,
            app: app,
            details: details,
            context: (marker?.context ?? backgroundContext?.context)?.attributes,
            recentEvents: recentEvents,
            fingerprintSeed: "crash|\(detectedAt.timeIntervalSince1970)"
        )
    }
}

/// The context when the app last went to the background, kept so a crash
/// during background playback still says what the app was doing.
struct AppHealthBackgroundContext: Codable, Equatable {
    let pid: Int32
    let context: AppHealthContextSnapshot
}

/// Current context, shared by the watchdog and the exit marker.
enum AppHealthContext {
    private static let state = OSAllocatedUnfairLock(initialState: AppHealthContextSnapshot())

    static func snapshot() -> AppHealthContextSnapshot {
        state.withLock { $0 }
    }

    static func update(_ change: (inout AppHealthContextSnapshot) -> Void) -> AppHealthContextSnapshot {
        state.withLockUnchecked { snapshot in
            change(&snapshot)
            return snapshot
        }
    }
}
#endif
