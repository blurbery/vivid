#if os(iOS) || os(tvOS)
import Foundation

/// Reports that describe the same kind of problem in the same situation,
/// shown as one row so a repeating fault does not make the page long.
struct AppHealthReportGroup: Identifiable, Equatable {
    let id: String
    let kind: AppHealthReport.Kind
    let summary: String
    /// Newest first.
    let reports: [AppHealthReport]

    var latest: AppHealthReport { reports[0] }

    /// `summary` in the app language, for display. `summary` stays English
    /// because it goes into the reports sent to Vivid.
    var displaySummary: String { latest.displaySummary }

    /// Every time the problem happened, counting repeats kept on one report.
    var occurrenceCount: Int { reports.reduce(0) { $0 + $1.occurrenceCount } }

    /// Groups ordered by when their problem last happened.
    static func grouping(_ reports: [AppHealthReport]) -> [AppHealthReportGroup] {
        var order: [String] = []
        var members: [String: [AppHealthReport]] = [:]
        for report in reports.sorted(by: { $0.lastOccurredAt > $1.lastOccurredAt }) {
            let key = report.groupKey
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(report)
        }
        return order.compactMap { key in
            guard let group = members[key], let first = group.first else { return nil }
            return AppHealthReportGroup(id: key, kind: first.kind, summary: first.groupSummary, reports: group)
        }
    }
}

extension AppHealthReport {
    /// Kind, source and situation, plus the top frame for MetricKit stacks
    /// and the failing request for app errors, so different faults of the
    /// same kind stay apart.
    var groupKey: String {
        [kind.rawValue, source.rawValue, groupSummary, topFrame ?? "", failingRequest ?? ""].joined(separator: "|")
    }

    /// A plain-English title, such as "Crashed: invalid memory access" or
    /// "Froze during playback". Contains no personal detail. Always English:
    /// it feeds `groupKey`, `issueID` and the reports sent to Vivid, which
    /// must match on every device whatever its language.
    var groupSummary: String { summary(localized: false) }

    /// `groupSummary` in the app language, for display only.
    var displaySummary: String { summary(localized: true) }

    private func summary(localized: Bool) -> String {
        switch kind {
        case .crash:
            let cause: String
            if details["exception_name"] != nil {
                cause = localized ? String(localized: "unhandled error", comment: "Crash cause in “Crashed: %@”") : "unhandled error"
            } else if case .int(let signal) = details["signal"] {
                cause = Self.signalMeaning(signal, localized: localized)
            } else {
                cause = localized ? String(localized: "unknown cause", comment: "Crash cause in “Crashed: %@”") : "unknown cause"
            }
            let during = crashSituation(localized: localized)
            guard localized else { return "Crashed" + (during.map { " \($0)" } ?? "") + ": " + cause }
            if let during { return String(localized: "Crashed \(during): \(cause)", comment: "Diagnostics problem title, e.g. “Crashed during playback: invalid memory access”") }
            return String(localized: "Crashed: \(cause)", comment: "Diagnostics problem title, e.g. “Crashed: invalid memory access”")
        case .unexpectedExit:
            let place = situation(localized: localized)
            guard localized else {
                let during = place.map { " \($0)" } ?? ""
                if details["likely_cause"] == .string("hang") { return "Closed by the system after freezing" + during }
                if details["likely_cause"] == .string("memory") { return "Closed by the system" + during + ", low on memory" }
                return "Closed unexpectedly" + during + " (cause unknown)"
            }
            if details["likely_cause"] == .string("hang") {
                if let place { return String(localized: "Closed by the system after freezing \(place)") }
                return String(localized: "Closed by the system after freezing")
            }
            if details["likely_cause"] == .string("memory") {
                if let place { return String(localized: "Closed by the system \(place), low on memory") }
                return String(localized: "Closed by the system, low on memory")
            }
            if let place { return String(localized: "Closed unexpectedly \(place) (cause unknown)") }
            return String(localized: "Closed unexpectedly (cause unknown)")
        case .hang:
            let place = situation(localized: localized)
            guard localized else { return "Froze" + (place.map { " \($0)" } ?? "") }
            if let place { return String(localized: "Froze \(place)", comment: "Diagnostics problem title, e.g. “Froze during playback”") }
            return String(localized: "Froze", comment: "Diagnostics problem title")
        case .playbackFailure:
            if case .string(let reason) = details["reason"] { return Self.playbackMeaning(reason, localized: localized) }
            return localized ? String(localized: "Playback failed") : "Playback failed"
        case .appError:
            return appErrorMeaning(localized: localized)
        case .downloadFailure:
            return downloadMeaning(localized: localized)
        case .cpuException:
            return localized ? String(localized: "Used too much processing power") : "Used too much processing power"
        case .diskWriteException:
            return localized ? String(localized: "Wrote too much data to storage") : "Wrote too much data to storage"
        case .slowLaunch:
            return localized ? String(localized: "Took too long to open") : "Took too long to open"
        }
    }

    /// A short ID for the kind of problem, such as `VD-3F9A2C`. The same
    /// problem gets the same ID on any device, day or app version, so reports
    /// from different people can be matched. It is built only from the
    /// problem itself: type, title, stable code, the failing request for app
    /// errors and, when MetricKit supplied a stack, the top frame. No time,
    /// device or person.
    var issueID: String {
        let stableCode = kind == .hang ? nil : technicalCode
        let seed = [kind.rawValue, groupSummary, stableCode ?? "", topFrame ?? "", failingRequest ?? ""]
            .joined(separator: "|")
        return "VD-" + DiagnosticsSHA256.shortHex(data: Data(seed.utf8), count: 6).uppercased()
    }

    /// The raw code behind the title, for the person diagnosing it: a signal
    /// name, exception name, failure token or error code.
    var technicalCode: String? {
        switch kind {
        case .crash:
            if case .string(let name) = details["exception_name"] { return name }
            if case .int(let signal) = details["signal"] { return Self.signalName(signal) }
            return nil
        case .playbackFailure:
            if case .string(let reason) = details["reason"] { return reason }
            return nil
        case .appError:
            var parts: [String] = []
            if case .string(let tag) = details["tag"] { parts.append(tag) }
            if case .int(let status) = details["status"] { parts.append("HTTP \(status)") }
            if case .string(let code) = details["error_code"] {
                parts.append(code)
            } else if case .string(let outcome) = details["outcome"] {
                parts.append(outcome)
            }
            if let failingRequest { parts.append(failingRequest) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .downloadFailure:
            var parts: [String] = []
            if case .string(let stage) = details["stage"] { parts.append(stage) }
            if case .int(let status) = details["status"] {
                parts.append("HTTP \(status)")
            } else if case .int(let code) = details["url_error"] {
                parts.append("URLError \(code)")
            }
            if case .string(let error) = details["error"], error != "http", error != "network" { parts.append(error) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .hang:
            if case .int(let ms) = details["duration_ms"] {
                return String(format: "%.1f s", Double(ms) / 1000)
            }
            return nil
        case .unexpectedExit, .cpuException, .diskWriteException, .slowLaunch:
            return nil
        }
    }

    /// The request an app error came from, such as
    /// `PUT /api/v2/settings/values/{id}`. The path was templated when it was
    /// logged, so it holds no IDs and matches across devices and launches.
    var failingRequest: String? {
        guard kind == .appError, case .string(let path) = details["path"], !path.isEmpty else { return nil }
        if case .string(let method) = details["method"], !method.isEmpty { return "\(method) \(path)" }
        return path
    }

    private func appErrorMeaning(localized: Bool) -> String {
        let tag: String? = { if case .string(let tag) = details["tag"] { return tag }; return nil }()
        switch tag {
        case "Decode": return localized ? String(localized: "Couldn't read a server response") : "Couldn't read a server response"
        case "Auth": return localized ? String(localized: "Sign-in problem with the server") : "Sign-in problem with the server"
        case "HTTP":
            if details["outcome"] == .string(HTTPDiagnosticsOutcome.decodeFailed) {
                return localized ? String(localized: "Couldn't read a server response") : "Couldn't read a server response"
            }
            if case .int(let status) = details["status"], status >= 500 {
                return localized ? String(localized: "Server error") : "Server error"
            }
            if case .int(let status) = details["status"], status == 401 || status == 403 {
                return localized ? String(localized: "Server refused access") : "Server refused access"
            }
            if case .int(let status) = details["status"], (400..<500).contains(status) {
                if case .string(let path) = details["path"], path.contains("/settings/"),
                   details["method"] != .string("GET") {
                    return localized ? String(localized: "Server rejected a settings change") : "Server rejected a settings change"
                }
                return localized ? String(localized: "Server rejected a request") : "Server rejected a request"
            }
            return localized ? String(localized: "Server request failed") : "Server request failed"
        default:
            if details["category"] == .string("network") {
                return localized ? String(localized: "Network problem") : "Network problem"
            }
            return localized ? String(localized: "Something went wrong") : "Something went wrong"
        }
    }

    private func downloadMeaning(localized: Bool) -> String {
        switch details["stage"] {
        case .string("registration"): return localized ? String(localized: "Couldn't start a download") : "Couldn't start a download"
        case .string("preparing"): return localized ? String(localized: "Couldn't prepare a download") : "Couldn't prepare a download"
        case .string("transfer"): return localized ? String(localized: "Download stopped before it finished") : "Download stopped before it finished"
        case .string("saving"): return localized ? String(localized: "Couldn't save a finished download") : "Couldn't save a finished download"
        case .string("conversion"): return localized ? String(localized: "Server couldn't prepare a download") : "Server couldn't prepare a download"
        default: return localized ? String(localized: "Download failed") : "Download failed"
        }
    }

    private static func playbackMeaning(_ reason: String, localized: Bool) -> String {
        switch reason {
        case "timeout": return localized ? String(localized: "Playback timed out") : "Playback timed out"
        case "not_found": return localized ? String(localized: "Playback failed: media not found on the server") : "Playback failed: media not found on the server"
        case "auth": return localized ? String(localized: "Playback failed: server refused access") : "Playback failed: server refused access"
        case "cancelled": return localized ? String(localized: "Playback was cancelled") : "Playback was cancelled"
        case "decode": return localized ? String(localized: "Playback failed: couldn't decode the media") : "Playback failed: couldn't decode the media"
        case "remux": return localized ? String(localized: "Playback failed: server couldn't prepare the stream") : "Playback failed: server couldn't prepare the stream"
        case "network": return localized ? String(localized: "Playback failed: network problem") : "Playback failed: network problem"
        default: return localized ? String(localized: "Playback failed") : "Playback failed"
        }
    }

    private static func signalMeaning(_ signal: Int, localized: Bool) -> String {
        guard localized else {
            switch signal {
            case 5: return "internal check failed"
            case 6: return "app stopped itself"
            case 10, 11: return "invalid memory access"
            case 4: return "invalid instruction"
            case 8: return "arithmetic error"
            default: return "system signal"
            }
        }
        switch signal {
        case 5: return String(localized: "internal check failed", comment: "Crash cause in “Crashed: %@”")
        case 6: return String(localized: "app stopped itself", comment: "Crash cause in “Crashed: %@”")
        case 10, 11: return String(localized: "invalid memory access", comment: "Crash cause in “Crashed: %@”")
        case 4: return String(localized: "invalid instruction", comment: "Crash cause in “Crashed: %@”")
        case 8: return String(localized: "arithmetic error", comment: "Crash cause in “Crashed: %@”")
        default: return String(localized: "system signal", comment: "Crash cause in “Crashed: %@”")
        }
    }

    /// "during playback", "while opening" or "while browsing".
    private func situation(localized: Bool) -> String? {
        guard let context else { return nil }
        if context["player_open"] == .bool(true) { return Self.duringPlayback(localized: localized) }
        if context["phase"] == .string("launching") {
            return localized ? String(localized: "while opening", comment: "Inserted into a diagnostics problem title, e.g. “Froze while opening”") : "while opening"
        }
        if context["phase"] == .string("browsing") {
            return localized ? String(localized: "while browsing", comment: "Inserted into a diagnostics problem title, e.g. “Froze while browsing”") : "while browsing"
        }
        return nil
    }

    /// Crashes can also happen in the background, where only playback (for
    /// example Picture in Picture) is worth calling out.
    private func crashSituation(localized: Bool) -> String? {
        if details["foreground"] == .bool(false) {
            if context?["player_open"] == .bool(true) { return Self.duringPlayback(localized: localized) }
            return localized ? String(localized: "in the background", comment: "Inserted into a diagnostics problem title, e.g. “Crashed in the background: invalid memory access”") : "in the background"
        }
        return situation(localized: localized)
    }

    private static func duringPlayback(localized: Bool) -> String {
        localized ? String(localized: "during playback", comment: "Inserted into a diagnostics problem title, e.g. “Froze during playback”") : "during playback"
    }

    /// The first frame of the stack MetricKit attributes the problem to.
    private var topFrame: String? {
        guard case .object(let tree) = callStackTree,
              case .array(let stacks) = tree["callStacks"] else { return nil }
        let attributed = stacks.first { stack in
            if case .object(let fields) = stack { return fields["threadAttributed"] == .bool(true) }
            return false
        } ?? stacks.first
        guard case .object(let stack) = attributed,
              case .array(let roots) = stack["callStackRootFrames"],
              case .object(let frame) = roots.first else { return nil }
        var parts: [String] = []
        if case .string(let name) = frame["binaryName"] { parts.append(name) }
        if case .int(let offset) = frame["offsetIntoBinaryTextSegment"] { parts.append(String(offset)) }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    private static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 8: return "SIGFPE"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        default: return "Signal \(signal)"
        }
    }
}

/// Which reports have been sent to Vivid, so the main button sends only new
/// ones and the Settings row counts only unsent reports.
enum AppHealthSendState {
    private static let sentIDsKey = "vivid.health.sentReportIDs"
    /// Well above the store's report cap, so pruning only drops IDs of
    /// reports that have already been deleted.
    private static let maxRemembered = 200

    static func sentIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: sentIDsKey) ?? [])
    }

    static func markSent(_ reports: [AppHealthReport]) {
        var ids = UserDefaults.standard.stringArray(forKey: sentIDsKey) ?? []
        for report in reports where !ids.contains(report.id) { ids.append(report.id) }
        UserDefaults.standard.set(Array(ids.suffix(maxRemembered)), forKey: sentIDsKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppHealthStore.didChange, object: nil)
        }
    }

    /// Called when a sent report happens again, so its new occurrences are
    /// sent next time.
    static func markUnsent(id: String) {
        guard var ids = UserDefaults.standard.stringArray(forKey: sentIDsKey), ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        UserDefaults.standard.set(ids, forKey: sentIDsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: sentIDsKey)
    }

    static func unsent(in reports: [AppHealthReport], sentIDs: Set<String> = sentIDs()) -> [AppHealthReport] {
        reports.filter { !sentIDs.contains($0.id) }
    }
}
#endif
