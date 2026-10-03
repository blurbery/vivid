#if os(iOS) || os(tvOS)
import Foundation

/// A short log of recent app events (screens, playback steps, auth changes,
/// failed requests and errors) attached to health reports, so a report shows
/// what led up to the problem.
///
/// It reuses the essential-tier `DiagTrace` lines, which are fixed messages
/// and state tokens. Lines go through the same redaction as the debug log,
/// and playback session IDs and the per-launch run ID are removed. The log is
/// kept in memory and written to a small file so it survives a crash; it
/// never leaves the device except inside a report the person sends.
enum AppHealthTrail {
    static let capacity = 60
    /// Lines attached to one report.
    static let reportLines = 40
    static let maxMessageLength = 300
    private static let flushDelay: DispatchTimeInterval = .seconds(3)
    private static let droppedAttributes: Set<String> = ["session_id"]

    static let queue = DispatchQueue(label: "com.blurbery.vivid.health.trail", qos: .utility)

    /// Set once at launch by `AppHealthMonitor`. Off under the test runner.
    nonisolated(unsafe) static var isEnabled = false

    // Confined to `queue`.
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var flushScheduled = false

    private static var fileURL: URL {
        AppHealthStore.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("HealthState", isDirectory: true)
            .appendingPathComponent("recent-events.json")
    }

    /// Called by `DiagTrace` for essential lines. Values are captured here;
    /// redaction and encoding happen off the calling thread.
    static func record(
        level: DiagnosticsLogLevel,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue]
    ) {
        guard isEnabled else { return }
        let timestamp = Date()
        let message = String(message.prefix(maxMessageLength))
        let attrs = attrs.filter { !droppedAttributes.contains($0.key) }
        queue.async {
            guard let rendered = DiagLog.renderedLine(
                level: level, category: category, tag: tag,
                message: message, attrs: attrs,
                timestamp: timestamp, captureSessionID: "-"
            ), let line = readableLine(rendered) else { return }
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
            scheduleFlush(immediately: level == .warning || level == .error)
        }
    }

    /// The most recent lines, including any still being rendered. Must not
    /// be called on `queue`; use `recentOnQueue()` there.
    static func recent(_ count: Int = reportLines) -> [String] {
        queue.sync { recentOnQueue(count) }
    }

    static func recentOnQueue(_ count: Int = reportLines) -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        return Array(lines.suffix(count))
    }

    /// Writes the log now, for moments a crash would be costly to miss
    /// (player open and close, going to the background).
    static func flushSoon() {
        guard isEnabled else { return }
        queue.async { scheduleFlush(immediately: true) }
    }

    /// The previous session's log. Call before this session records anything.
    static func collectPrevious() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let previous = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: fileURL)
        return Array(previous.suffix(reportLines))
    }

    /// `05:17:30Z W network/HTTP request failed status=500`, built from the
    /// already-redacted line so nothing skips redaction.
    static func readableLine(_ rendered: String) -> String? {
        guard let line = try? JSONDecoder().decode(DiagnosticsLogLine.self, from: Data(rendered.utf8)) else { return nil }
        let time = line.ts.split(separator: "T").last.map(String.init) ?? line.ts
        var text = "\(time) \(line.lvl.rawValue) \(line.cat.rawValue)/\(line.tag) \(line.msg)"
        for key in (line.attrs ?? [:]).keys.sorted() {
            guard let value = line.attrs?[key] else { continue }
            switch value {
            case .string(let string): text += " \(key)=\(string)"
            case .int(let number): text += " \(key)=\(number)"
            case .double(let number): text += " \(key)=\(number)"
            case .bool(let flag): text += " \(key)=\(flag)"
            case .null, .array, .object: continue
            }
        }
        return text
    }

    private static func scheduleFlush(immediately: Bool) {
        if immediately {
            flush()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { flush() }
    }

    private static func flush() {
        flushScheduled = false
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}
#endif
