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
    /// "Froze during playback". Contains no personal detail.
    var groupSummary: String {
        switch kind {
        case .crash:
            let cause: String
            if details["exception_name"] != nil {
                cause = "unhandled error"
            } else if case .int(let signal) = details["signal"] {
                cause = Self.signalMeaning(signal)
            } else {
                cause = "unknown cause"
            }
            return "Crashed" + (crashSituation.map { " \($0)" } ?? "") + ": " + cause
        case .unexpectedExit:
            let during = situation.map { " \($0)" } ?? ""
            if details["likely_cause"] == .string("hang") { return "Closed by the system after freezing" + during }
            if details["likely_cause"] == .string("memory") { return "Closed by the system" + during + ", low on memory" }
            return "Closed unexpectedly" + during + " (cause unknown)"
        case .hang:
            return "Froze" + (situation.map { " \($0)" } ?? "")
        case .playbackFailure:
            if case .string(let reason) = details["reason"] { return Self.playbackMeaning(reason) }
            return "Playback failed"
        case .appError:
            return appErrorMeaning
        case .cpuException:
            return "Used too much processing power"
        case .diskWriteException:
            return "Wrote too much data to storage"
        case .slowLaunch:
            return "Took too long to open"
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

    private var appErrorMeaning: String {
        let tag: String? = { if case .string(let tag) = details["tag"] { return tag }; return nil }()
        switch tag {
        case "Decode": return "Couldn't read a server response"
        case "Auth": return "Sign-in problem with the server"
        case "HTTP":
            if details["outcome"] == .string(HTTPDiagnosticsOutcome.decodeFailed) { return "Couldn't read a server response" }
            if case .int(let status) = details["status"], status >= 500 { return "Server error" }
            if case .int(let status) = details["status"], status == 401 || status == 403 { return "Server refused access" }
            if case .int(let status) = details["status"], (400..<500).contains(status) {
                if case .string(let path) = details["path"], path.contains("/settings/"),
                   details["method"] != .string("GET") {
                    return "Server rejected a settings change"
                }
                return "Server rejected a request"
            }
            return "Server request failed"
        default:
            if details["category"] == .string("network") { return "Network problem" }
            return "Something went wrong"
        }
    }

    private static func playbackMeaning(_ reason: String) -> String {
        switch reason {
        case "timeout": return "Playback timed out"
        case "not_found": return "Playback failed: media not found on the server"
        case "auth": return "Playback failed: server refused access"
        case "cancelled": return "Playback was cancelled"
        case "decode": return "Playback failed: couldn't decode the media"
        case "remux": return "Playback failed: server couldn't prepare the stream"
        case "network": return "Playback failed: network problem"
        default: return "Playback failed"
        }
    }

    private static func signalMeaning(_ signal: Int) -> String {
        switch signal {
        case 5: return "internal check failed"
        case 6: return "app stopped itself"
        case 10, 11: return "invalid memory access"
        case 4: return "invalid instruction"
        case 8: return "arithmetic error"
        default: return "system signal"
        }
    }

    /// "during playback", "while opening" or "while browsing".
    private var situation: String? {
        guard let context else { return nil }
        if context["player_open"] == .bool(true) { return "during playback" }
        if context["phase"] == .string("launching") { return "while opening" }
        if context["phase"] == .string("browsing") { return "while browsing" }
        return nil
    }

    /// Crashes can also happen in the background, where only playback (for
    /// example Picture in Picture) is worth calling out.
    private var crashSituation: String? {
        if details["foreground"] == .bool(false) {
            return context?["player_open"] == .bool(true) ? "during playback" : "in the background"
        }
        return situation
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

    static func clear() {
        UserDefaults.standard.removeObject(forKey: sentIDsKey)
    }

    static func unsent(in reports: [AppHealthReport], sentIDs: Set<String> = sentIDs()) -> [AppHealthReport] {
        reports.filter { !sentIDs.contains($0.id) }
    }
}
#endif
