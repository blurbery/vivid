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

    /// A short ID for the kind of problem, such as `VD-3F9A2C`. The same
    /// problem gets the same ID on any device, day or app version, so reports
    /// from different people can be matched. It is built only from the
    /// problem itself: type, title, stable code, the failing request for app
    /// errors and, when MetricKit supplied a stack, the top frame. No time,
    /// device or person.
    var issueID: String {
        // A hang's code is its duration, which differs every time.
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
            if let name = detailString("exception_name") { return name }
            return detailInt("signal").map(Self.signalName)
        case .playbackFailure:
            return detailString("reason")
        case .appError:
            var parts: [String] = []
            if let tag = detailString("tag") { parts.append(tag) }
            if let status = detailInt("status") { parts.append("HTTP \(status)") }
            if let code = detailString("error_code") ?? detailString("outcome") { parts.append(code) }
            if let failingRequest { parts.append(failingRequest) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .downloadFailure:
            var parts: [String] = []
            if let stage = detailString("stage") { parts.append(stage) }
            if let status = detailInt("status") {
                parts.append("HTTP \(status)")
            } else if let code = detailInt("url_error") {
                parts.append("URLError \(code)")
            }
            // "http" and "network" only repeat what the status or URL error says.
            if let error = detailString("error"), error != "http", error != "network" { parts.append(error) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .hang:
            return detailInt("duration_ms").map { String(format: "%.1f s", Double($0) / 1000) }
        case .unexpectedExit, .cpuException, .diskWriteException, .slowLaunch:
            return nil
        }
    }

    /// The request an app error came from, such as
    /// `PUT /api/v2/settings/values/{id}`. The path was templated when it was
    /// logged, so it holds no IDs and matches across devices and launches.
    var failingRequest: String? {
        guard kind == .appError, let path = detailString("path"), !path.isEmpty else { return nil }
        if let method = detailString("method"), !method.isEmpty { return "\(method) \(path)" }
        return path
    }

    // MARK: - Titles

    private func summary(localized: Bool) -> String {
        switch kind {
        case .crash:
            return crashSummary(localized: localized)
        case .unexpectedExit:
            return exitSummary(localized: localized)
        case .hang:
            let place = situation(localized: localized)
            guard localized else { return "Froze" + (place.map { " \($0)" } ?? "") }
            if let place { return String(localized: "Froze \(place)", comment: "Diagnostics problem title, e.g. “Froze during playback”") }
            return String(localized: "Froze", comment: "Diagnostics problem title")
        case .playbackFailure:
            if let reason = detailString("reason") { return Self.playbackMeaning(reason, localized: localized) }
            return Self.pick(localized, "Playback failed", String(localized: "Playback failed"))
        case .appError:
            return appErrorMeaning(localized: localized)
        case .downloadFailure:
            return downloadMeaning(localized: localized)
        case .cpuException:
            return Self.pick(localized, "Used too much processing power", String(localized: "Used too much processing power"))
        case .diskWriteException:
            return Self.pick(localized, "Wrote too much data to storage", String(localized: "Wrote too much data to storage"))
        case .slowLaunch:
            return Self.pick(localized, "Took too long to open", String(localized: "Took too long to open"))
        }
    }

    private func crashSummary(localized: Bool) -> String {
        let cause: String
        if details["exception_name"] != nil {
            cause = Self.pick(localized, "unhandled error", String(localized: "unhandled error", comment: "Crash cause in “Crashed: %@”"))
        } else if let signal = detailInt("signal") {
            cause = Self.signalMeaning(signal, localized: localized)
        } else {
            cause = Self.pick(localized, "unknown cause", String(localized: "unknown cause", comment: "Crash cause in “Crashed: %@”"))
        }
        let during = crashSituation(localized: localized)
        guard localized else { return "Crashed" + (during.map { " \($0)" } ?? "") + ": " + cause }
        if let during { return String(localized: "Crashed \(during): \(cause)", comment: "Diagnostics problem title, e.g. “Crashed during playback: invalid memory access”") }
        return String(localized: "Crashed: \(cause)", comment: "Diagnostics problem title, e.g. “Crashed: invalid memory access”")
    }

    private func exitSummary(localized: Bool) -> String {
        let place = situation(localized: localized)
        let likelyCause = detailString("likely_cause")
        guard localized else {
            let during = place.map { " \($0)" } ?? ""
            switch likelyCause {
            case "hang": return "Closed by the system after freezing" + during
            case "memory": return "Closed by the system" + during + ", low on memory"
            default: return "Closed unexpectedly" + during + " (cause unknown)"
            }
        }
        switch likelyCause {
        case "hang":
            if let place { return String(localized: "Closed by the system after freezing \(place)") }
            return String(localized: "Closed by the system after freezing")
        case "memory":
            if let place { return String(localized: "Closed by the system \(place), low on memory") }
            return String(localized: "Closed by the system, low on memory")
        default:
            if let place { return String(localized: "Closed unexpectedly \(place) (cause unknown)") }
            return String(localized: "Closed unexpectedly (cause unknown)")
        }
    }

    private func appErrorMeaning(localized: Bool) -> String {
        switch detailString("tag") {
        case "Decode":
            return Self.pick(localized, "Couldn't read a server response", String(localized: "Couldn't read a server response"))
        case "Auth":
            return Self.pick(localized, "Sign-in problem with the server", String(localized: "Sign-in problem with the server"))
        case "HTTP":
            let status = detailInt("status")
            if details["outcome"] == .string(HTTPDiagnosticsOutcome.decodeFailed) {
                return Self.pick(localized, "Couldn't read a server response", String(localized: "Couldn't read a server response"))
            }
            if let status, status >= 500 {
                return Self.pick(localized, "Server error", String(localized: "Server error"))
            }
            if status == 401 || status == 403 {
                return Self.pick(localized, "Server refused access", String(localized: "Server refused access"))
            }
            if let status, (400..<500).contains(status) {
                if let path = detailString("path"), path.contains("/settings/"), details["method"] != .string("GET") {
                    return Self.pick(localized, "Server rejected a settings change", String(localized: "Server rejected a settings change"))
                }
                return Self.pick(localized, "Server rejected a request", String(localized: "Server rejected a request"))
            }
            return Self.pick(localized, "Server request failed", String(localized: "Server request failed"))
        default:
            if details["category"] == .string("network") {
                return Self.pick(localized, "Network problem", String(localized: "Network problem"))
            }
            return Self.pick(localized, "Something went wrong", String(localized: "Something went wrong"))
        }
    }

    private func downloadMeaning(localized: Bool) -> String {
        switch detailString("stage") {
        case "registration": return Self.pick(localized, "Couldn't start a download", String(localized: "Couldn't start a download"))
        case "preparing": return Self.pick(localized, "Couldn't prepare a download", String(localized: "Couldn't prepare a download"))
        case "transfer": return Self.pick(localized, "Download stopped before it finished", String(localized: "Download stopped before it finished"))
        case "saving": return Self.pick(localized, "Couldn't save a finished download", String(localized: "Couldn't save a finished download"))
        case "conversion": return Self.pick(localized, "Server couldn't prepare a download", String(localized: "Server couldn't prepare a download"))
        default: return Self.pick(localized, "Download failed", String(localized: "Download failed"))
        }
    }

    private static func playbackMeaning(_ reason: String, localized: Bool) -> String {
        switch reason {
        case "timeout": return pick(localized, "Playback timed out", String(localized: "Playback timed out"))
        case "not_found": return pick(localized, "Playback failed: media not found on the server", String(localized: "Playback failed: media not found on the server"))
        case "auth": return pick(localized, "Playback failed: server refused access", String(localized: "Playback failed: server refused access"))
        case "cancelled": return pick(localized, "Playback was cancelled", String(localized: "Playback was cancelled"))
        case "decode": return pick(localized, "Playback failed: couldn't decode the media", String(localized: "Playback failed: couldn't decode the media"))
        case "remux": return pick(localized, "Playback failed: server couldn't prepare the stream", String(localized: "Playback failed: server couldn't prepare the stream"))
        case "network": return pick(localized, "Playback failed: network problem", String(localized: "Playback failed: network problem"))
        default: return pick(localized, "Playback failed", String(localized: "Playback failed"))
        }
    }

    private static func signalMeaning(_ signal: Int, localized: Bool) -> String {
        switch signal {
        case 5: return pick(localized, "internal check failed", String(localized: "internal check failed", comment: "Crash cause in “Crashed: %@”"))
        case 6: return pick(localized, "app stopped itself", String(localized: "app stopped itself", comment: "Crash cause in “Crashed: %@”"))
        case 10, 11: return pick(localized, "invalid memory access", String(localized: "invalid memory access", comment: "Crash cause in “Crashed: %@”"))
        case 4: return pick(localized, "invalid instruction", String(localized: "invalid instruction", comment: "Crash cause in “Crashed: %@”"))
        case 8: return pick(localized, "arithmetic error", String(localized: "arithmetic error", comment: "Crash cause in “Crashed: %@”"))
        default: return pick(localized, "system signal", String(localized: "system signal", comment: "Crash cause in “Crashed: %@”"))
        }
    }

    /// "during playback", "while opening" or "while browsing".
    private func situation(localized: Bool) -> String? {
        guard let context else { return nil }
        if context["player_open"] == .bool(true) { return Self.duringPlayback(localized: localized) }
        if context["phase"] == .string("launching") {
            return Self.pick(localized, "while opening", String(localized: "while opening", comment: "Inserted into a diagnostics problem title, e.g. “Froze while opening”"))
        }
        if context["phase"] == .string("browsing") {
            return Self.pick(localized, "while browsing", String(localized: "while browsing", comment: "Inserted into a diagnostics problem title, e.g. “Froze while browsing”"))
        }
        return nil
    }

    /// Crashes can also happen in the background, where only playback (for
    /// example Picture in Picture) is worth calling out.
    private func crashSituation(localized: Bool) -> String? {
        guard details["foreground"] == .bool(false) else { return situation(localized: localized) }
        if context?["player_open"] == .bool(true) { return Self.duringPlayback(localized: localized) }
        return Self.pick(localized, "in the background", String(localized: "in the background", comment: "Inserted into a diagnostics problem title, e.g. “Crashed in the background: invalid memory access”"))
    }

    private static func duringPlayback(localized: Bool) -> String {
        pick(localized, "during playback", String(localized: "during playback", comment: "Inserted into a diagnostics problem title, e.g. “Froze during playback”"))
    }

    /// The English text, or its translation for display. Both are spelled out
    /// at each call so the String Catalog keeps finding the translated one.
    private static func pick(_ localized: Bool, _ english: String, _ translated: @autoclosure () -> String) -> String {
        localized ? translated() : english
    }

    // MARK: - Details

    private func detailString(_ key: String) -> String? {
        if case .string(let value) = details[key] { return value }
        return nil
    }

    private func detailInt(_ key: String) -> Int? {
        if case .int(let value) = details[key] { return value }
        return nil
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
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        default: return "Signal \(signal)"
        }
    }
}
#endif
