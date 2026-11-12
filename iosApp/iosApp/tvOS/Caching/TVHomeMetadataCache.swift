#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit
import CoreGraphics
#if os(tvOS)
import SwiftUI
#endif

/// Home's rows, spotlight slides and library list, saved on the device for
/// each server, account and profile, so Home paints at once on the next
/// launch. Only enabled rows are kept, and the artwork they show is warmed
/// into the disk cache. It's a disposable cache: clearing it removes nothing
/// from the server.
@Observable
@MainActor
final class TVHomeMetadataCache {
    static let shared = TVHomeMetadataCache()

    struct Row: Codable {
        let section: ResolvedSection
        let updatedAt: Date
    }

    /// The saved file. Field names and the version are the on-disk format.
    struct Snapshot: Codable {
        var version = 1
        /// The language Vivid showed when this was saved, nil for English:
        /// the row titles Vivid names itself are in it.
        var language = VividAppLanguage.tmdbLanguage
        var rows: [Row] = []
        var spotlight: [TVHomeSpotlightSlide] = []
        var spotlightUpdatedAt: Date?
        var details: [String: ItemDetail] = [:]
        var libraries: LibrariesResponse?
        /// Optional, so snapshots saved before it existed still load.
        var spotlightPreparation: [String: SpotlightPreparation]?
    }

    /// The crop and tint worked out for one spotlight artwork URL.
    struct SpotlightPreparation: Codable, Equatable {
        var cropVersion = 1
        var subject: CGRect?
        var cropPrepared = false
        var tint: [Double]?
        /// Missing on tints saved before the main-colour sampling (an
        /// average), which are worked out again.
        var tintVersion: Int?
    }

    /// One entry on the Metadata settings page.
    struct Status: Identifiable {
        let id: String
        let title: String
        let count: Int
        let updatedAt: Date?
    }

    static let spotlightID = "vivid.cache.spotlight"
    nonisolated private static let maximumSnapshotBytes = 8 * 1024 * 1024
    nonisolated private static let currentCropVersion = 1
    nonisolated private static let currentTintVersion = 2

    private(set) var snapshot = Snapshot()
    private(set) var storageError: String?

    /// Spotlight crop and tint records, keyed by artwork URL.
    @ObservationIgnored private var preparedSpotlight: [String: SpotlightPreparation] = [:]
    #if os(tvOS)
    @ObservationIgnored private var cropTasks: [String: Task<CGRect?, Never>] = [:]
    @ObservationIgnored private var tintTasks: [String: Task<Color?, Never>] = [:]
    #endif
    @ObservationIgnored private var loadedScope: String?
    /// Bumped whenever loaded state is replaced or cleared, so work started
    /// before then can tell it's stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var enrichmentTask: Task<Void, Never>?
    @ObservationIgnored private var warmedURLs = Set<URL>()
    @ObservationIgnored private let writer: HomeMetadataWriter
    @ObservationIgnored private let snapshotDirectory: URL?
    @ObservationIgnored private let currentScope: () -> String?
    /// Bumped on every save, so only the latest save reports its outcome.
    @ObservationIgnored private var saveRevision: UInt64 = 0
    @ObservationIgnored private var preparedSnapshot: (scope: String, value: Snapshot?)?
    @ObservationIgnored private var preparation: (scope: String, task: Task<Snapshot?, Never>)?
    @ObservationIgnored private let prefetcher = VividImagePrefetcher(
        pipeline: VividImagePipeline.shared, destination: .diskCache, maxConcurrentRequestCount: 2
    )

    init(writer: HomeMetadataWriter = HomeMetadataWriter(), snapshotDirectory: URL? = nil,
         currentScope: @escaping () -> String? = { VividCacheScope.current }) {
        self.writer = writer
        self.snapshotDirectory = snapshotDirectory
        self.currentScope = currentScope
    }

    private var activeScope: String? { currentScope() }

    private func fileURL(for scope: String) -> URL {
        let directory = snapshotDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Vivid/HomeMetadata/v2", isDirectory: true)
        return directory.appendingPathComponent(scope + ".json")
    }

    // MARK: Loading

    /// Reads the current scope's snapshot on the writer queue, so launch and
    /// profile changes wait only for local I/O. Home can then hydrate from
    /// memory before its first render. Callers preparing the same scope share
    /// one read.
    func prepare() async {
        guard let scope = activeScope, scope != loadedScope else { return }
        let expectedGeneration = generation
        let task: Task<Snapshot?, Never>
        if let existing = preparation, existing.scope == scope {
            task = existing.task
        } else {
            preparation?.task.cancel()
            let url = fileURL(for: scope)
            task = Task { [writer] in
                await writer.read { Self.readSnapshot(at: url) }
            }
            preparation = (scope, task)
        }
        let saved = await task.value
        guard !Task.isCancelled, !task.isCancelled,
              generation == expectedGeneration, activeScope == scope,
              loadedScope != scope else { return }
        // Activate without another await, so no save or clear can slip in
        // between checking this read and applying it.
        preparedSnapshot = (scope, saved)
        activate()
    }

    nonisolated private static func readSnapshot(at url: URL) -> Snapshot? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumSnapshotBytes,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
              saved.version == 1,
              saved.language == VividAppLanguage.tmdbLanguage else { return nil }
        return saved
    }

    /// Loads the current scope's snapshot, from a prepared read when there
    /// is one, otherwise by reading it now.
    func activate() {
        let scope = activeScope
        guard loadedScope != scope else { return }
        let prepared = preparedSnapshot
        deactivate()
        loadedScope = scope
        guard let scope else { return }
        let saved: Snapshot?
        if let prepared, prepared.scope == scope {
            saved = prepared.value
        } else {
            // Keeps first paint for direct callers. Startup and profile
            // selection prepare on the writer queue instead.
            let url = fileURL(for: scope)
            saved = writer.sync { Self.readSnapshot(at: url) }
        }
        guard let saved else { return }
        snapshot = saved
        #if os(tvOS)
        // Older snapshots kept detail pages. Apple TV's Home doesn't use them.
        snapshot.details.removeAll()
        #endif
        preparedSpotlight = saved.spotlightPreparation ?? [:]
        if MediaServerProvider.active == .emby {
            snapshot.rows.removeAll {
                EmbyAdapter.excludesHomeRow(id: $0.section.id, type: $0.section.sectionType, title: $0.section.title)
            }
            snapshot.spotlight.removeAll { EmbyAdapter.excludesHomeRow(id: $0.rowID, type: "", title: $0.rowTitle) }
        }
        reconcilePreferences()
    }

    /// Forgets the loaded scope and stops everything working for it.
    func deactivate() {
        generation += 1
        preparation?.task.cancel()
        preparation = nil
        preparedSnapshot = nil
        cancelSpotlightWork()
        prefetcher.stopPrefetching()
        warmedURLs.removeAll()
        loadedScope = nil
        snapshot = Snapshot()
        preparedSpotlight.removeAll()
        storageError = nil
    }

    /// Fills the response cache from the snapshot where it has nothing yet,
    /// so Home paints before the network answers.
    func hydrate() {
        activate()
        let responses = ResponseCache.shared
        if responses.get(CacheKey.homeSections, as: SectionsResponse.self) == nil,
           !snapshot.rows.isEmpty || snapshot.spotlightUpdatedAt != nil {
            var sections = snapshot.rows.map(\.section)
            // Silo's spotlight can come from rows Home hides. Rebuild those
            // rows from their slides, so the spotlight paints too.
            if !MediaServerProvider.active.usesNativeUser {
                for slide in snapshot.spotlight where !sections.contains(where: { $0.id == slide.rowID }) {
                    sections.append(ResolvedSection(
                        id: slide.rowID, sectionType: "spotlight", title: slide.rowTitle,
                        featured: false, itemLimit: 20, totalCount: nil,
                        isCustom: nil, customized: nil,
                        items: snapshot.spotlight.filter { $0.rowID == slide.rowID }.map(\.item)
                    ))
                }
            }
            responses.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        }
        if let libraries = snapshot.libraries,
           responses.get(CacheKey.userLibraries, as: LibrariesResponse.self) == nil {
            responses.set(libraries, for: CacheKey.userLibraries)
        }
        #if os(iOS)
        for (id, detail) in snapshot.details {
            responses.set(detail, for: CacheKey.itemDetail(id))
        }
        #endif
    }

    // MARK: Updates

    /// Every row cut to its first 20 items.
    static func capped(_ response: SectionsResponse) -> SectionsResponse {
        SectionsResponse(sections: response.sections.map { section in
            ResolvedSection(
                id: section.id, sectionType: section.sectionType, title: section.title,
                featured: section.featured, itemLimit: min(section.itemLimit ?? 20, 20),
                totalCount: section.totalCount, isCustom: section.isCustom,
                customized: section.customized, items: Array(section.items.prefix(20))
            )
        })
    }

    /// Saves a fresh Home response: the enabled rows and the spotlight they
    /// feed. An unchanged response only retries artwork and preparation.
    func store(_ response: SectionsResponse) {
        activate()
        guard loadedScope != nil else { return }
        let previousArtwork = artworkURLs(in: snapshot)
        #if os(iOS)
        let previousSlideItems = Dictionary(snapshot.spotlight.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        #endif
        let now = Date()
        let limited = Self.capped(response)
        let home = HomeSectionPreferences.shared
        let spotlight = TVHomeSpotlightPreferences.shared
        home.refresh()
        spotlight.initializeIfNeeded(from: limited.sections)
        let rows = limited.sections.filter { home.isVisible($0.id) }
        let slides = spotlight.slides(from: limited.sections)
        if snapshot.rows.map(\.section) == rows, snapshot.spotlight == slides,
           snapshot.spotlightUpdatedAt != nil, storageError == nil {
            // Failed or evicted artwork and missing details stay retryable
            // without rewriting an unchanged snapshot on every refresh.
            replaceArtwork(previous: previousArtwork)
            enrichSpotlight()
            return
        }
        snapshot.rows = rows.map { Row(section: $0, updatedAt: now) }
        snapshot.spotlight = slides
        snapshot.spotlightUpdatedAt = now
        #if os(iOS)
        let slideIDs = spotlightDetailIDs
        snapshot.details = snapshot.details.filter { slideIDs.contains($0.key) }
        // A slide whose item changed needs its details read again.
        for slide in snapshot.spotlight {
            guard let previous = previousSlideItems[slide.id], previous != slide.item else { continue }
            for id in Self.detailContentIDs(for: slide.item) {
                snapshot.details.removeValue(forKey: id)
                ResponseCache.shared.remove(CacheKey.itemDetail(id))
            }
        }
        for id in slideIDs {
            if let detail: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(id)) {
                snapshot.details[id] = detail
            }
        }
        #endif
        replaceArtwork(previous: previousArtwork)
        save()
        enrichSpotlight()
    }

    func storeLibraries(_ libraries: LibrariesResponse) {
        activate()
        guard loadedScope != nil else { return }
        snapshot.libraries = libraries
        save()
    }

    /// Drops rows the person has hidden and slides from rows the spotlight
    /// no longer uses.
    func reconcilePreferences() {
        guard loadedScope != nil else { return }
        let home = HomeSectionPreferences.shared
        let spotlight = TVHomeSpotlightPreferences.shared
        home.refresh()
        spotlight.refresh()
        let previousArtwork = artworkURLs(in: snapshot)
        snapshot.rows.removeAll { !home.isVisible($0.section.id) }
        if let ids = spotlight.selectedRowIDs {
            snapshot.spotlight.removeAll { !ids.contains($0.rowID) }
        }
        let slideIDs = spotlightDetailIDs
        snapshot.details = snapshot.details.filter { slideIDs.contains($0.key) }
        replaceArtwork(previous: previousArtwork)
        save()
    }

    // MARK: Settings

    /// Spotlight first, then the enabled rows in Home's order.
    var statuses: [Status] {
        let home = HomeSectionPreferences.shared
        var statuses = [Status(id: Self.spotlightID, title: String(localized: "Spotlight"),
                               count: snapshot.spotlight.count, updatedAt: snapshot.spotlightUpdatedAt)]
        let live: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        let sourceRows = live?.sections ?? snapshot.rows.map(\.section)
        let sections = home.arrangedSections(sourceRows)
            + sourceRows.filter { $0.items.isEmpty && home.isVisible($0.id) }
        for section in sections {
            let saved = snapshot.rows.first { $0.section.id == section.id }
            statuses.append(Status(id: section.id, title: section.title,
                                   count: saved?.section.items.count ?? 0, updatedAt: saved?.updatedAt))
        }
        for saved in snapshot.rows where home.isVisible(saved.section.id)
            && !statuses.contains(where: { $0.id == saved.section.id }) {
            statuses.append(Status(id: saved.section.id, title: saved.section.title,
                                   count: saved.section.items.count, updatedAt: saved.updatedAt))
        }
        return statuses
    }

    /// Clears one entry on the Metadata settings page: the spotlight, or one row.
    func clear(_ id: String) {
        activate()
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        generation += 1
        cancelSpotlightWork()
        let previousArtwork = artworkURLs(in: snapshot)
        if id == Self.spotlightID {
            preparedSpotlight.removeAll()
            snapshot.spotlight.removeAll()
            snapshot.spotlightUpdatedAt = nil
            for key in snapshot.details.keys { ResponseCache.shared.remove(CacheKey.itemDetail(key)) }
            snapshot.details.removeAll()
        } else {
            snapshot.rows.removeAll { $0.section.id == id }
        }
        replaceArtwork(previous: previousArtwork)
        save()
    }

    // MARK: Account removal

    func deleteAccountCache(_ account: TVSavedAccount) async throws {
        guard let profileID = account.profile?.id else { return }
        let scope = VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: profileID)
        if loadedScope == scope || preparation?.scope == scope { deactivate() }
        let url = fileURL(for: scope)
        let artwork: Set<URL> = try await withCheckedThrowingContinuation { continuation in
            writer.async {
                continuation.resume(with: Result { try Self.deleteSnapshot(at: url) })
            }
        }
        PosterImageCache.stopPrefetchingCardArtwork(Array(artwork))
        await VividImagePipeline.shared.removeCachedArtwork(for: artwork, scope: scope)
    }

    /// Deletes a snapshot file and returns every web URL it named, so their
    /// artwork can go too. A file that isn't valid JSON is still deleted.
    nonisolated static func deleteSnapshot(at url: URL) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let urls = (try? JSONSerialization.jsonObject(with: data)).map(webURLs(in:)) ?? []
        try FileManager.default.removeItem(at: url)
        return urls
    }

    nonisolated private static func webURLs(in value: Any) -> Set<URL> {
        if let string = value as? String, let url = URL(string: string),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return [url] }
        if let values = value as? [Any] { return values.reduce(into: []) { $0.formUnion(webURLs(in: $1)) } }
        if let values = value as? [String: Any] { return values.values.reduce(into: []) { $0.formUnion(webURLs(in: $1)) } }
        return []
    }

    // MARK: Artwork

    /// The base for Silo's relative artwork paths.
    private var artworkBase: URL? {
        MediaServerProvider.active == .silo ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
    }

    /// The artwork the saved rows and slides show, series backgrounds included.
    private func artworkURLs(in value: Snapshot) -> Set<URL> {
        let backdrops = HomeSeriesBackdrops.shared
        var strings: [String] = []
        for row in value.rows {
            if HomeSeriesBackdrops.applies(toSectionType: row.section.sectionType) {
                strings += row.section.items.map { backdrops.art(for: $0).url }
            } else {
                strings += row.section.items.compactMap(\.posterUrl)
            }
        }
        for slide in value.spotlight {
            strings += [backdrops.art(for: slide.item).url, slide.item.posterUrl, slide.item.logoUrl]
                .compactMap { $0 }.filter { !$0.isEmpty }
            #if os(iOS)
            strings += [value.details[slide.id]?.backdropUrl].compactMap { $0 }
            #endif
        }
        let base = artworkBase
        return Set(strings.compactMap { raw in
            guard let url = SiloAPICompatibility.artworkURL(raw, relativeTo: base),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        })
    }

    /// Evicts artwork the snapshot no longer shows and warms what it does,
    /// including anything a failed download or the system evicted.
    private func replaceArtwork(previous: Set<URL>) {
        let pipeline = VividImagePipeline.shared
        let desired = artworkURLs(in: snapshot)
        let removed = previous.subtracting(desired)
        let retained = Set(desired.map(\.absoluteString))
        preparedSpotlight = preparedSpotlight.filter { retained.contains($0.key) }
        prefetcher.stopPrefetching(with: Array(warmedURLs.subtracting(desired)))
        PosterImageCache.stopPrefetchingCardArtwork(Array(removed))
        for url in removed {
            pipeline.cache.removeCachedData(for: VividImageRequest(url: url))
            pipeline.cache.removeCachedImage(for: VividImageRequest(url: url), caches: .memory)
            pipeline.cache.removeCachedImage(for: PosterImageCache.cardWarmRequest(for: url), caches: .memory)
        }
        prefetcher.priority = .low
        prefetcher.startPrefetching(with: desired
            .filter { !pipeline.cache.containsData(for: VividImageRequest(url: $0)) }
            .map { VividImageRequest(url: $0, priority: .low) })
        warmedURLs = desired
    }

    // MARK: Spotlight details

    /// iOS episode slides show their series' year and ratings, so the
    /// series' details are saved alongside the episode's.
    static func detailContentIDs(for item: SectionItem) -> [String] {
        #if os(iOS)
        if MediaServerProvider.active.usesNativeUser, item.type == "episode",
           let seriesID = item.seriesId, seriesID != item.contentId {
            return [item.contentId, seriesID]
        }
        #endif
        return [item.contentId]
    }

    func spotlightMetadata(for item: SectionItem) -> ItemDetail? {
        guard MediaServerProvider.active.usesNativeUser,
              let id = Self.detailContentIDs(for: item).last else { return nil }
        return snapshot.details[id]
    }

    private var spotlightDetailIDs: Set<String> {
        Set(snapshot.spotlight.flatMap { Self.detailContentIDs(for: $0.item) })
    }

    /// iOS reads the details its spotlight labels use. Apple TV labels come
    /// from the Home items, so it only prepares each slide's crop and tint.
    private func enrichSpotlight() {
        enrichmentTask?.cancel()
        let expectedGeneration = generation
        let scope = loadedScope
        enrichmentTask = Task { @MainActor in
            let stillCurrent = { self.isCurrent(generation: expectedGeneration, scope: scope) }
            #if os(iOS)
            var seen = Set<String>()
            let ids = snapshot.spotlight.flatMap { Self.detailContentIDs(for: $0.item) }
                .filter { seen.insert($0).inserted }
            for id in ids where snapshot.details[id] == nil {
                guard stillCurrent() else { return }
                let detail: ItemDetail
                if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(id)) {
                    detail = cached
                } else if let fetched = try? await MetadataRequestPool.shared.itemDetail(contentId: id) {
                    detail = fetched
                } else {
                    continue
                }
                guard stillCurrent(),
                      snapshot.spotlight.contains(where: { Self.detailContentIDs(for: $0.item).contains(id) })
                else { return }
                let previousArtwork = artworkURLs(in: snapshot)
                snapshot.details[id] = detail
                ResponseCache.shared.set(detail, for: CacheKey.itemDetail(id))
                replaceArtwork(previous: previousArtwork)
                save()
            }
            #endif
            #if os(tvOS)
            // One at a time, with the same analysis and records the visible
            // carousel uses.
            var prepared = Set<String>()
            let base = artworkBase
            for slide in snapshot.spotlight {
                guard let raw = slide.content.backdropUrl, prepared.insert(raw).inserted else { continue }
                guard stillCurrent() else { return }
                guard let url = SiloAPICompatibility.artworkURL(raw, relativeTo: base) else { continue }
                let record = preparedSpotlight[raw]
                if record?.cropPrepared != true || record?.cropVersion != Self.currentCropVersion {
                    let request = PosterImageCache.displayRequest(url: url, pixelSize: CGSize(width: 768, height: 768), priority: .low)
                    if let image = try? await VividImagePipeline.shared.image(for: request) {
                        guard stillCurrent() else { return }
                        _ = await preparedSpotlightSubject(in: image, url: raw)
                    }
                }
                guard stillCurrent() else { return }
                _ = await preparedSpotlightTint(for: url)
            }
            #endif
        }
    }

    /// Whether enrichment started for this generation and scope may go on.
    private func isCurrent(generation expectedGeneration: Int, scope: String?) -> Bool {
        !Task.isCancelled && expectedGeneration == generation && scope == activeScope
    }

    private func cancelSpotlightWork() {
        #if os(tvOS)
        cropTasks.values.forEach { $0.cancel() }
        tintTasks.values.forEach { $0.cancel() }
        cropTasks.removeAll()
        tintTasks.removeAll()
        #endif
        enrichmentTask?.cancel()
        enrichmentTask = nil
    }

    // MARK: Spotlight crop and tint

    #if os(tvOS)
    /// A tint worked out earlier. Starts no work.
    func cachedSpotlightTint(for url: URL) -> Color? {
        guard let record = preparedSpotlight[url.absoluteString], record.tintVersion == Self.currentTintVersion,
              let rgb = record.tint, rgb.count == 3 else { return nil }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// Where the subject sits in an artwork image, from the saved record or
    /// worked out now. A slide that disappears doesn't cancel the shared
    /// work another slide or the cache may be waiting on; account changes do.
    func preparedSpotlightSubject(in image: UIImage, url: String) async -> CGRect? {
        if let record = preparedSpotlight[url], record.cropPrepared, record.cropVersion == Self.currentCropVersion {
            return record.subject
        }
        let expectedGeneration = generation
        let scope = loadedScope
        let task: Task<CGRect?, Never>
        if let existing = cropTasks[url] {
            task = existing
        } else {
            let key = (scope ?? VividCacheScope.artwork) + "|" + url
            task = Task.detached(priority: .utility) { await TVSpotlightCrop.prepareSubject(in: image, key: key) }
            cropTasks[url] = task
        }
        let subject = await task.value
        if expectedGeneration == generation { cropTasks.removeValue(forKey: url) }
        guard !Task.isCancelled, expectedGeneration == generation, scope == loadedScope else { return subject }
        updateSpotlightPreparation(url: url) {
            $0.cropVersion = Self.currentCropVersion
            $0.cropPrepared = true
            $0.subject = subject
        }
        return subject
    }

    /// The artwork's tint, from the saved record or worked out now.
    func preparedSpotlightTint(for url: URL) async -> Color? {
        if let tint = cachedSpotlightTint(for: url) { return tint }
        let expectedGeneration = generation
        let scope = loadedScope
        let key = url.absoluteString
        let task: Task<Color?, Never>
        if let existing = tintTasks[key] {
            task = existing
        } else {
            task = Task { await HeroBackdropPalette.spotlightTintColor(for: url) }
            tintTasks[key] = task
        }
        let result = await task.value
        if expectedGeneration == generation { tintTasks.removeValue(forKey: key) }
        guard let tint = result,
              !Task.isCancelled, expectedGeneration == generation, scope == loadedScope else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if UIColor(tint).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            updateSpotlightPreparation(url: key) {
                $0.tint = [Double(red), Double(green), Double(blue)]
                $0.tintVersion = Self.currentTintVersion
            }
        }
        return tint
    }

    /// Saves a record only for artwork the snapshot still shows, and only
    /// when it changed.
    private func updateSpotlightPreparation(url: String, update: (inout SpotlightPreparation) -> Void) {
        guard loadedScope != nil, artworkURLs(in: snapshot).contains(where: { $0.absoluteString == url }) else { return }
        var record = preparedSpotlight[url] ?? SpotlightPreparation()
        update(&record)
        guard preparedSpotlight[url] != record else { return }
        preparedSpotlight[url] = record
        save()
    }
    #endif

    // MARK: Saving

    /// Queues a save of the snapshot. Only the latest save for the same
    /// loaded state updates `storageError`.
    private func save() {
        guard let scope = loadedScope else { return }
        saveRevision &+= 1
        let revision = saveRevision
        let expectedGeneration = generation
        var value = snapshot
        value.spotlightPreparation = preparedSpotlight.isEmpty ? nil : preparedSpotlight
        let url = fileURL(for: scope)
        writer.write(scope: scope) {
            let failure: String?
            do {
                let data = try JSONEncoder().encode(value)
                guard data.count <= Self.maximumSnapshotBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                failure = nil
            } catch {
                failure = String(localized: "Couldn’t save the Home cache. It will retry on the next refresh.")
            }
            Task { @MainActor [weak self] in
                guard let self, self.loadedScope == scope,
                      self.generation == expectedGeneration,
                      self.saveRevision == revision else { return }
                self.storageError = failure
            }
        }
    }
}
#endif
