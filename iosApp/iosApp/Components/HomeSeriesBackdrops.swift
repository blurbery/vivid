import Foundation
import Observation
import SwiftUI

/// Series backgrounds for episodes on Home's Continue Watching and Next Up
/// cards. Movies keep their own background.
///
/// Emby sends the series background as the episode's backdrop, and Jellyfin
/// keeps it in `seriesBackdropUrl`. Silo's Home rows carry the episode still
/// instead, so Vivid looks each series up once, a few at a time, and keeps
/// the answer on disk for the server and profile until shortly before its
/// signed link expires.
@Observable @MainActor
final class HomeSeriesBackdrops {
    static let shared = HomeSeriesBackdrops()

    struct Artwork: Codable, Equatable {
        let url: String
        let thumbhash: String?
        let expiresAt: Date
    }

    private struct CacheFile: Codable {
        var version = 1
        var entries: [String: Artwork]
    }

    private struct Scope: Equatable {
        let server: String
        let profile: String

        @MainActor static var current: Scope? {
            guard let server = ServerRegistry.shared.activeServerId,
                  let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
            return Scope(server: server, profile: profile)
        }

        var cacheURL: URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return nil }
            let folder = caches.appendingPathComponent("HomeSeriesBackdrops", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("backdrops-v1-\(token).json")
        }
    }

    /// Bumped when a lookup lands, so the cards showing it redraw.
    private(set) var revision = 0
    // Read while cards draw, so loading from disk must not publish a change.
    @ObservationIgnored private var entries: [String: Artwork] = [:]
    @ObservationIgnored private var loadedScope: Scope?
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var failedAt: [String: Date] = [:]

    /// Home rows whose episode cards show the series background.
    nonisolated static func applies(toSectionType type: String) -> Bool {
        ["continue_watching", "in_progress", "next_up"].contains(type.lowercased())
    }

    /// The artwork for a Continue Watching or Next Up card on Home: the
    /// series background for an episode once it's known, otherwise the
    /// item's own background or poster, with the thumbhash to match.
    func art(for item: SectionItem) -> (url: String, thumbhash: String?) {
        _ = revision
        if item.type.lowercased() == "episode" {
            if let url = item.seriesBackdropUrl, !url.isEmpty { return (url, item.seriesBackdropThumbhash) }
            if let seriesID = item.seriesId, let saved = saved(seriesID) { return (saved.url, saved.thumbhash) }
        }
        if let backdrop = item.backdropUrl, !backdrop.isEmpty { return (backdrop, item.backdropThumbhash) }
        return (item.posterUrl ?? "", item.posterThumbhash)
    }

    /// Looks up the series of Silo episodes in these rows that don't have a
    /// background saved yet. Each series is asked for once; one that fails
    /// is tried again after ten minutes.
    func prepare(_ items: [SectionItem]) {
        guard MediaServerProvider.active == .silo else { return }
        loadIfNeeded()
        guard let scope = loadedScope else { return }
        let now = Date()
        let wanted = Set(items.compactMap { item -> String? in
            guard item.type.lowercased() == "episode", (item.seriesBackdropUrl ?? "").isEmpty,
                  let seriesID = item.seriesId, !seriesID.isEmpty else { return nil }
            return seriesID
        }).filter { id in
            saved(id, at: now) == nil && !inFlight.contains(id)
                && (failedAt[id].map { now.timeIntervalSince($0) > 600 } ?? true)
        }.sorted()
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        Task { [weak self] in
            var results: [String: ItemDetail?] = [:]
            // Four at a time, so a full row doesn't crowd out Home's own requests.
            for start in stride(from: 0, to: wanted.count, by: 4) {
                let batch = wanted[start..<min(start + 4, wanted.count)]
                await withTaskGroup(of: (String, ItemDetail?).self) { group in
                    for id in batch {
                        group.addTask { (id, try? await VividAPI.shared.itemDetail(contentId: id)) }
                    }
                    for await (id, detail) in group { results[id] = detail }
                }
            }
            self?.store(results, scope: scope)
        }
    }

    /// Removing a saved account removes its saved backgrounds too.
    nonisolated static func removeCache(server: String, profile: String) {
        if let url = Scope(server: server, profile: profile).cacheURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func store(_ results: [String: ItemDetail?], scope: Scope) {
        inFlight.subtract(results.keys)
        guard scope == loadedScope else { return }
        let now = Date()
        for (id, detail) in results {
            guard let detail, let url = detail.backdropUrl, !url.isEmpty else {
                failedAt[id] = now
                continue
            }
            failedAt.removeValue(forKey: id)
            // A link without an expiry is still refreshed weekly.
            entries[id] = Artwork(url: url, thumbhash: detail.backdropThumbhash,
                                  expiresAt: SiloAPICompatibility.artworkExpiry(url) ?? now.addingTimeInterval(7 * 86_400))
        }
        entries = entries.filter { $0.value.expiresAt > now }
        if let fileURL = scope.cacheURL, let data = try? JSONEncoder().encode(CacheFile(entries: entries)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        revision += 1
    }

    /// A saved background that stays valid for at least another hour.
    private func saved(_ seriesID: String, at now: Date = Date()) -> Artwork? {
        loadIfNeeded()
        guard let artwork = entries[seriesID], artwork.expiresAt > now.addingTimeInterval(3600) else { return nil }
        return artwork
    }

    private func loadIfNeeded() {
        let scope = Scope.current
        guard scope != loadedScope else { return }
        loadedScope = scope
        inFlight = []
        failedAt = [:]
        entries = scope?.cacheURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(CacheFile.self, from: $0) }
            .flatMap { $0.version == 1 ? $0.entries : nil } ?? [:]
    }
}

extension EnvironmentValues {
    /// Set by Home's feed, so its Continue Watching and Next Up rows show
    /// series backgrounds while the same rows elsewhere keep episode stills.
    @Entry var showsHomeSeriesBackdrops = false
}
