#if os(iOS) || os(tvOS)
import Foundation

/// Which reports have been sent to Vivid, so the main button sends only new
/// ones and the Settings row counts only unsent reports.
enum AppHealthSendState {
    private static let sentIDsKey = "vivid.health.sentReportIDs"
    /// Well above the store's report cap, so pruning only drops IDs of
    /// reports that have already been deleted.
    private static let maxRemembered = 200

    private static var savedIDs: [String]? {
        UserDefaults.standard.stringArray(forKey: sentIDsKey)
    }

    static func sentIDs() -> Set<String> {
        Set(savedIDs ?? [])
    }

    static func markSent(_ reports: [AppHealthReport]) {
        var ids = savedIDs ?? []
        for report in reports where !ids.contains(report.id) { ids.append(report.id) }
        UserDefaults.standard.set(Array(ids.suffix(maxRemembered)), forKey: sentIDsKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppHealthStore.didChange, object: nil)
        }
    }

    /// Called when a sent report happens again, so its new occurrences are
    /// sent next time.
    static func markUnsent(id: String) {
        guard var ids = savedIDs, ids.contains(id) else { return }
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
