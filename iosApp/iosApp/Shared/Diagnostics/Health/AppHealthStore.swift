#if os(iOS) || os(tvOS)
import Foundation

/// Keeps health reports on this device, capped by count, size and age.
///
/// There is no upload path. Reports leave the device only through the share
/// action in Settings, and Delete All removes every file.
final class AppHealthStore: Sendable {
    struct Limits: Sendable, Equatable {
        let maxReports: Int
        let maxBytes: Int
        let maxAge: TimeInterval
        /// App errors have their own small cap on top of the overall one.
        var maxAppErrors = 5

        #if os(tvOS)
        // tvOS gives apps very little guaranteed local storage, and these
        // files live in Caches, which the system may purge.
        static let platformDefault = Limits(maxReports: 20, maxBytes: 1024 * 1024, maxAge: 14 * 24 * 60 * 60)
        #else
        static let platformDefault = Limits(maxReports: 20, maxBytes: 2 * 1024 * 1024, maxAge: 14 * 24 * 60 * 60)
        #endif
    }

    static let didChange = Notification.Name("vividAppHealthReportsChanged")

    static let shared = AppHealthStore(directory: defaultDirectory, limits: .platformDefault)

    static var defaultDirectory: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("HealthReports", isDirectory: true)
    }

    private let directory: URL
    private let limits: Limits
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    init(directory: URL, limits: Limits, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    /// Stores a report unless one with the same ID is already kept. Returns
    /// whether it was added.
    @discardableResult
    func add(_ report: AppHealthReport) -> Bool {
        var counted = false
        let added: Bool = lock.withLock {
            guard prepareDirectory() else { return false }
            if Self.countsRepeats(report), let existing = repeatTarget(for: report),
               existing.report.id != report.id {
                // The same problem again: count it on the report already kept
                // rather than listing it once per launch.
                if let data = try? Self.encoder.encode(existing.report.repeated(at: report.recordedAt)) {
                    counted = (try? data.write(to: existing.url, options: [.atomic])) != nil
                }
                return false
            }
            let url = fileURL(for: report.id)
            guard !FileManager.default.fileExists(atPath: url.path),
                  let data = try? Self.encoder.encode(report) else { return false }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                return false
            }
            prune()
            return FileManager.default.fileExists(atPath: url.path)
        }
        if added || counted { notifyChange() }
        return added
    }

    /// Repeats of the same issue within this window update one report.
    static let repeatWindow: TimeInterval = 24 * 60 * 60

    /// Problems that can recur on every launch or playback. Crashes, exits
    /// and MetricKit reports stay separate, since each carries its own
    /// details worth keeping.
    static func countsRepeats(_ report: AppHealthReport) -> Bool {
        switch report.kind {
        case .appError, .playbackFailure:
            return true
        case .hang:
            return report.source == .watchdog
        default:
            return false
        }
    }

    /// The kept report for the same issue, first seen within the repeat
    /// window. Caller holds `lock`.
    private func repeatTarget(for report: AppHealthReport) -> StoredReport? {
        let issueID = report.issueID
        return loadAll().first {
            $0.report.issueID == issueID
                && $0.report.source == report.source
                && report.recordedAt.timeIntervalSince($0.report.recordedAt) < Self.repeatWindow
        }
    }

    /// Folds a MetricKit crash into the report the crash capture already made
    /// for the same process, so one crash is not listed twice. Returns false
    /// when there is no such report.
    func merge(metricKitCrash incoming: AppHealthReport, pid: Int) -> Bool {
        let merged: Bool = lock.withLock {
            guard let match = loadAll().first(where: {
                ($0.report.kind == .crash || $0.report.kind == .unexpectedExit)
                    && $0.report.details["pid"] == .int(pid)
                    && $0.report.callStackTree == nil
            }), let data = try? Self.encoder.encode(match.report.merging(metricKit: incoming)) else { return false }
            return (try? data.write(to: match.url, options: [.atomic])) != nil
        }
        if merged { notifyChange() }
        return merged
    }

    /// Kept reports, newest first.
    func reports() -> [AppHealthReport] {
        lock.withLock {
            prune()
            return loadAll().map(\.report)
        }
    }

    func removeAll() {
        lock.withLock {
            try? FileManager.default.removeItem(at: directory)
        }
        notifyChange()
    }

    /// The file that is sent, in the same form the detail screen shows.
    func exportData(_ reports: [AppHealthReport]) -> Data {
        let export = AppHealthExport(
            format: AppHealthReport.formatVersion,
            exportedAt: now(),
            reports: reports.map(AppHealthExport.Entry.init)
        )
        return (try? Self.encoder.encode(export)) ?? Data()
    }

    // MARK: - Files

    private struct StoredReport {
        let url: URL
        let size: Int
        let report: AppHealthReport
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    private func prepareDirectory() -> Bool {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
            #if os(iOS)
            // Reports describe this device only; keep them out of backups.
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            #endif
        }
        return true
    }

    /// Newest first. Unreadable files are removed rather than kept forever.
    private func loadAll() -> [StoredReport] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var stored: [StoredReport] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let report = try? Self.decoder.decode(AppHealthReport.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            stored.append(StoredReport(url: url, size: data.count, report: report))
        }
        return stored.sorted { $0.report.recordedAt > $1.report.recordedAt }
    }

    /// Drops reports past the age limit and app errors beyond their cap, then,
    /// while over the count or byte limit, the oldest report of the lowest
    /// retention priority. Caller holds `lock`.
    private func prune() {
        let cutoff = now().addingTimeInterval(-limits.maxAge)
        var kept: [StoredReport] = []
        var appErrors = 0
        for stored in loadAll() {
            var fits = stored.report.recordedAt >= cutoff
            if fits, stored.report.kind == .appError {
                appErrors += 1
                fits = appErrors <= limits.maxAppErrors
            }
            if fits {
                kept.append(stored)
            } else {
                try? FileManager.default.removeItem(at: stored.url)
            }
        }
        var bytes = kept.reduce(0) { $0 + $1.size }
        while kept.count > limits.maxReports || bytes > limits.maxBytes {
            // `kept` is newest first, so the last match is the oldest.
            guard let lowest = kept.map(\.report.kind.retentionPriority).min(),
                  let index = kept.lastIndex(where: { $0.report.kind.retentionPriority == lowest }) else { break }
            let removed = kept.remove(at: index)
            bytes -= removed.size
            try? FileManager.default.removeItem(at: removed.url)
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct AppHealthExport: Codable {
    /// One report as sent: its plain title and issue ID alongside the data.
    struct Entry: Codable {
        let issueID: String
        let title: String
        let report: AppHealthReport

        init(_ report: AppHealthReport) {
            self.issueID = report.issueID
            self.title = report.groupSummary
            self.report = report
        }
    }

    let format: Int
    let exportedAt: Date
    let reports: [Entry]
}
#endif
