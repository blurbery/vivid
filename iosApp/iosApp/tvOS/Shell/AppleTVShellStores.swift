#if os(tvOS)
import Foundation

/// Remembers the title whose trailer was handed to YouTube, so a cold
/// launch soon after can reopen it for the same server and profile.
struct TVTrailerReturnStore {
    static let shared = TVTrailerReturnStore()

    private static let recordKey = "trailerReturn.record"
    /// Only the first launch check in a process may restore.
    @MainActor private static var hasConsumed = false

    func saveHandoff(contentId: String) {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty,
              let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty else { return }
        let record = TrailerReturnRecord(contentId: contentId, serverId: serverId, profileId: profileId, savedAt: Date())
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: Self.recordKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.recordKey)
    }

    /// The title to reopen on this launch, if any. The record is always
    /// removed.
    @MainActor
    func consumeColdLaunchRestore(now: Date = Date()) -> String? {
        let data = UserDefaults.standard.data(forKey: Self.recordKey)
        UserDefaults.standard.removeObject(forKey: Self.recordKey)
        guard !Self.hasConsumed else { return nil }
        Self.hasConsumed = true
        guard let data, let record = try? JSONDecoder().decode(TrailerReturnRecord.self, from: data) else { return nil }
        let restores = TrailerReturnPolicy.shouldRestore(
            record: record,
            now: now,
            activeServerId: ServerRegistry.shared.activeServerId,
            activeProfileId: AuthService.shared.profileId
        )
        return restores ? record.contentId : nil
    }
}
#endif
