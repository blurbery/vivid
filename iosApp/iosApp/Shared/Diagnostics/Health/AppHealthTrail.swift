import Foundation

/// The last few essential trace lines in readable form, so a health report
/// can show what the app was doing before a problem. Saved to disk so the
/// next launch can recover them after a crash. They leave the device only
/// inside a report the person chooses to send.
enum AppHealthTrail {
    static let queue = DispatchQueue(label: "com.blurbery.vivid.health.trail", qos: .utility)

    /// Turned on once by the health monitor at launch, never under tests.
    nonisolated(unsafe) static var isEnabled = false

    static let capacity = 60
    static let reportLineCount = 40
    static let messageLimit = 300
    static let saveDelay: TimeInterval = 3

    // Touched only on `queue`.
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var saveScheduled = false

    /// Called for each line kept for reports. The work is queued before this
    /// returns, so later work on `queue` sees the line.
    static func record(
        level: DiagnosticsLogLevel,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue]
    ) {
        guard isEnabled else { return }
        let timestamp = Date()
        let message = String(message.prefix(messageLimit))
        var attrs = attrs
        attrs.removeValue(forKey: "session_id")
        queue.async {
            guard let rendered = DiagLog.renderedLine(
                level: level, category: category, tag: tag, message: message, attrs: attrs,
                timestamp: timestamp, captureSessionID: "-"),
                  let line = readableLine(fromRendered: rendered)
            else { return }
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
            if level == .warning || level == .error {
                save()
            } else {
                scheduleSave()
            }
        }
    }

    static func recent(_ count: Int = 40) -> [String] {
        queue.sync { Array(lines.suffix(count)) }
    }

    static func recentOnQueue(_ count: Int = 40) -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        return Array(lines.suffix(count))
    }

    static func flushSoon() {
        guard isEnabled else { return }
        queue.async { save() }
    }

    /// The previous process's lines. Reads and deletes the file straight away,
    /// so call it before recording starts.
    static func collectPrevious() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let previous = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        try? FileManager.default.removeItem(at: fileURL)
        return Array(previous.suffix(reportLineCount))
    }

    /// `14:13:20.000Z E network/Refresh could not renew sign-in attempt=2`.
    static func readableLine(fromRendered rendered: String) -> String? {
        guard let line = try? JSONDecoder().decode(DiagnosticsLogLine.self, from: Data(rendered.utf8)) else { return nil }
        let time = line.ts.split(separator: "T").last.map(String.init) ?? line.ts
        var text = "\(time) \(line.lvl.rawValue) \(line.cat.rawValue)/\(line.tag) \(line.msg)"
        for (key, value) in (line.attrs ?? [:]).sorted(by: { $0.key < $1.key }) {
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

    // MARK: - File

    private static var fileURL: URL {
        AppHealthStore.defaultDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("HealthState", isDirectory: true)
            .appendingPathComponent("recent-events.json")
    }

    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + saveDelay) { save() }
    }

    private static func save() {
        saveScheduled = false
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(lines).write(to: url, options: .atomic)
        } catch {
            // The trail is a best-effort aid; losing a save loses nothing else.
        }
    }
}
