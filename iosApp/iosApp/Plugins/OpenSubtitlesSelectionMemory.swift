#if os(iOS) || os(tvOS)
import CryptoKit
import Foundation

/// Remembers the OpenSubtitles file chosen for an item, so stopping and
/// resuming it later brings the same subtitle back. The index and files stay
/// on this device, scoped to the server account and profile, and never enter
/// the iCloud vault.
@MainActor
final class OpenSubtitlesSelectionMemory {
    struct Record: Codable, Equatable {
        let key: String
        let resultID: Int
        let name: String
        let language: String
        let hearingImpaired: Bool
        var savedAt: Date
    }

    static let shared = OpenSubtitlesSelectionMemory()
    static let countLimit = 40

    private let defaults: UserDefaults
    private let directory: URL
    private let now: () -> Date
    private var loaded: [String: [Record]] = [:]

    init(
        defaults: UserDefaults = .standard,
        directory: URL = OpenSubtitlesSelectionMemory.defaultDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.directory = directory
        self.now = now
    }

    /// tvOS has no writable Application Support; Caches may be purged, in
    /// which case the item simply falls back to its normal subtitle choice.
    nonisolated static var defaultDirectory: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("OpenSubtitles", isDirectory: true)
    }

    func remember(_ result: OpenSubtitleResult, data: Data, scope: String, contentID: String, fileID: Int?) {
        guard !data.isEmpty else { return }
        let key = Self.key(contentID: contentID, fileID: fileID)
        let url = fileURL(scope: scope, key: key)
        var records = records(for: scope)
        if let index = records.firstIndex(where: { $0.key == key }),
           records[index].resultID == result.id,
           FileManager.default.fileExists(atPath: url.path) {
            records[index].savedAt = now()
        } else {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Re-downloadable, so keep it out of device backups.
                var root = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? root.setResourceValues(values)
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
            records.removeAll { $0.key == key }
            records.append(Record(key: key, resultID: result.id, name: result.name,
                language: result.language, hearingImpaired: result.hearingImpaired, savedAt: now()))
        }
        records.sort { $0.savedAt > $1.savedAt }
        for stale in records.dropFirst(Self.countLimit) {
            try? FileManager.default.removeItem(at: fileURL(scope: scope, key: stale.key))
        }
        save(Array(records.prefix(Self.countLimit)), scope: scope)
    }

    func record(scope: String, contentID: String, fileID: Int?) -> Record? {
        let key = Self.key(contentID: contentID, fileID: fileID)
        return records(for: scope).first { $0.key == key }
    }

    func restore(scope: String, contentID: String, fileID: Int?) -> (result: OpenSubtitleResult, data: Data)? {
        guard let record = record(scope: scope, contentID: contentID, fileID: fileID) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(scope: scope, key: record.key)), !data.isEmpty else {
            forget(scope: scope, contentID: contentID, fileID: fileID)
            return nil
        }
        let result = OpenSubtitleResult(id: record.resultID, name: record.name,
            language: record.language, hearingImpaired: record.hearingImpaired)
        return (result, data)
    }

    func forget(scope: String, contentID: String, fileID: Int?) {
        let key = Self.key(contentID: contentID, fileID: fileID)
        var records = records(for: scope)
        guard records.contains(where: { $0.key == key }) else { return }
        records.removeAll { $0.key == key }
        try? FileManager.default.removeItem(at: fileURL(scope: scope, key: key))
        save(records, scope: scope)
    }

    func clear(scope: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(scope, isDirectory: true))
        loaded[scope] = []
        defaults.removeObject(forKey: storageKey(scope))
    }

    static func key(contentID: String, fileID: Int?) -> String {
        let raw = contentID + "|" + (fileID.map(String.init) ?? "-")
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func storageKey(_ scope: String) -> String { "vivid.opensubtitles.selection.v1." + scope }

    private func fileURL(scope: String, key: String) -> URL {
        directory.appendingPathComponent(scope, isDirectory: true).appendingPathComponent(key + ".srt")
    }

    private func records(for scope: String) -> [Record] {
        if let cached = loaded[scope] { return cached }
        let decoded = defaults.data(forKey: storageKey(scope))
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        loaded[scope] = decoded
        return decoded
    }

    private func save(_ records: [Record], scope: String) {
        loaded[scope] = records
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: storageKey(scope))
        }
    }
}
#endif
