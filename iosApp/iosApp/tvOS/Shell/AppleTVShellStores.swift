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

extension TVMainTabView {
    /// Which library each Movies and Series page shows, per server and
    /// profile, across launches.
    @MainActor
    enum LibraryScopeMemory {
        private static func key(for type: TVLibraryTabType) -> String? {
            guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
            let serverId = ServerRegistry.shared.activeServerId ?? "default"
            return "skyline.libraryScope.\(serverId).\(profileId).\(type.rawValue)"
        }

        private static func storedLibraryId(for type: TVLibraryTabType) -> Int? {
            guard let key = key(for: type) else { return nil }
            let suite = SharedDefaults.shared.suite
            if suite.object(forKey: key) != nil { return suite.integer(forKey: key) }
            if UserDefaults.standard.object(forKey: key) != nil { return UserDefaults.standard.integer(forKey: key) }
            return nil
        }

        static func remember(_ libraryId: Int, for type: TVLibraryTabType) {
            guard let key = key(for: type) else { return }
            SharedDefaults.shared.suite.set(libraryId, forKey: key)
            UserDefaults.standard.set(libraryId, forKey: key)
        }

        /// The stored library when it's still offered, else the first.
        static func resolve(_ type: TVLibraryTabType, among libraries: [Library]) -> Library? {
            guard let first = libraries.first else { return nil }
            if let stored = storedLibraryId(for: type), let match = libraries.first(where: { $0.id == stored }) {
                return match
            }
            return first
        }
    }
}
#endif
