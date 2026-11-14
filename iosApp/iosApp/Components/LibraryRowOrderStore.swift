import Foundation
import Observation

/// The order a profile arranged its Library row in. It is saved per server
/// and profile and travels with the profile's other preferences through
/// iCloud, so rearranging on one device rearranges the others. Libraries it
/// hasn't placed follow in the server's order.
@Observable @MainActor
final class LibraryRowOrderStore {
    static let shared = LibraryRowOrderStore()

    /// Bumped by every change, here or from iCloud, so views that asked for
    /// an order read it again.
    private var revision = 0

    private init() {}

    /// Where an order is kept. `VividCloudPreferences` syncs keys of this
    /// shape for every saved account.
    nonisolated static func defaultsKey(serverId: String, profileId: String) -> String {
        "vivid.libraryRowOrder.v1.\(serverId).\(profileId)"
    }

    private var activeKey: String? {
        guard let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
        return Self.defaultsKey(serverId: ServerRegistry.shared.activeServerId ?? "default", profileId: profile)
    }

    private var savedOrder: [Int] {
        _ = revision
        guard let activeKey, let raw = SharedDefaults.shared.string(forKey: activeKey) else { return [] }
        return raw.split(separator: ",").compactMap { Int($0) }
    }

    /// The movie, series and mixed libraries in the server's order: by sort
    /// order (missing last), then id.
    nonisolated static func browsable(_ libraries: [Library]) -> [Library] {
        libraries.filter(\.isSupportedLibrary).sorted { lhs, rhs in
            let left = lhs.sortOrder ?? Int.max
            let right = rhs.sortOrder ?? Int.max
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    /// `libraries` as the profile arranged them.
    func ordered(_ libraries: [Library]) -> [Library] {
        Self.arranged(libraries, saved: savedOrder)
    }

    nonisolated static func arranged(_ libraries: [Library], saved: [Int]) -> [Library] {
        guard !saved.isEmpty else { return libraries }
        let placed = saved.compactMap { id in libraries.first { $0.id == id } }
        return placed + libraries.filter { !saved.contains($0.id) }
    }

    /// Moves a library one place within the row. `shown` is put in the saved
    /// order first: a caller's copy of the row dates from when it was last
    /// drawn, so a second move arriving before the row redraws would start
    /// from the old order and repeat the first move instead of adding to it.
    func move(_ library: Library, by offset: Int, in shown: [Library]) {
        let shown = Self.arranged(shown, saved: savedOrder)
        guard let activeKey, let index = shown.firstIndex(where: { $0.id == library.id }) else { return }
        let target = index + offset
        guard shown.indices.contains(target) else { return }
        var ids = shown.map(\.id)
        ids.swapAt(index, target)
        SharedDefaults.shared.set(ids.map(String.init).joined(separator: ","), forKey: activeKey)
        revision += 1
    }

    /// Another device's order arrived through iCloud.
    func cloudPreferencesChanged() {
        revision += 1
    }
}
