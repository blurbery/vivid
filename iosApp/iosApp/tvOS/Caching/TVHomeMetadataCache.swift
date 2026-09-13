#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit
import CoreGraphics
#if os(tvOS)
import SwiftUI
#endif

@Observable
@MainActor
final class TVHomeMetadataCache {
    static let shared = TVHomeMetadataCache()

    struct Row: Codable {
        let section: ResolvedSection
        let updatedAt: Date
    }

    struct Snapshot: Codable {
        var version = 1
        var rows: [Row] = []
        var spotlight: [TVHomeSpotlightSlide] = []
        var spotlightUpdatedAt: Date?
        var details: [String: ItemDetail] = [:]
        var libraries: LibrariesResponse?
        // Optional so existing full Home snapshots remain readable.
        var spotlightPreparation: [String: SpotlightPreparation]?
    }

    struct SpotlightPreparation: Codable, Equatable {
        var cropVersion = 1
        var subject: CGRect?
        var cropPrepared = false
        var tint: [Double]?
    }

    struct Status: Identifiable {
        let id: String
        let title: String
        let count: Int
        let updatedAt: Date?
    }

    private(set) var snapshot = Snapshot()
    private(set) var storageError: String?
    @ObservationIgnored private var preparedSpotlight: [String: SpotlightPreparation] = [:]
    #if os(tvOS)
    @ObservationIgnored private var cropTasks: [String: Task<CGRect?, Never>] = [:]
    @ObservationIgnored private var tintTasks: [String: Task<Color?, Never>] = [:]
    #endif
    @ObservationIgnored private var loadedScope: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var enrichmentTask: Task<Void, Never>?
    @ObservationIgnored private var warmedURLs = Set<URL>()
    @ObservationIgnored private let writer = DispatchQueue(label: "vivid.home.metadata", qos: .utility)
    @ObservationIgnored private let prefetcher = VividImagePrefetcher(
        pipeline: VividImagePipeline.shared, destination: .diskCache, maxConcurrentRequestCount: 2
    )

    nonisolated private static let maximumSnapshotBytes = 8 * 1024 * 1024
    static let spotlightID = "vivid.cache.spotlight"

    private var activeScope: String? {
        guard let server = ServerRegistry.shared.activeServerId,
              let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
        let data = (try? JSONEncoder().encode([server, profile])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for scope: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vivid/HomeMetadata/v1", isDirectory: true)
            .appendingPathComponent(scope + ".json")
    }

    func activate() {
        let scope = activeScope
        guard loadedScope != scope else { return }
        deactivate()
        loadedScope = scope
        guard let scope else { return }
        let url = fileURL(for: scope)
        let saved: Snapshot? = writer.sync {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumSnapshotBytes,
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode(Snapshot.self, from: data),
                  value.version == 1 else { return nil }
            return value
        }
        guard let saved else { return }
        snapshot = saved
        preparedSpotlight = saved.spotlightPreparation ?? [:]
        if MediaServerProvider.active == .emby {
            snapshot.rows.removeAll { EmbyAdapter.excludesHomeRow(id:$0.section.id,type:$0.section.sectionType,title:$0.section.title) }
            snapshot.spotlight.removeAll { EmbyAdapter.excludesHomeRow(id:$0.rowID,type:"",title:$0.rowTitle) }
        }
        reconcilePreferences()
    }

    func deactivate() {
        generation += 1
        #if os(tvOS)
        cropTasks.values.forEach { $0.cancel() }
        tintTasks.values.forEach { $0.cancel() }
        cropTasks.removeAll()
        tintTasks.removeAll()
        #endif
        enrichmentTask?.cancel()
        enrichmentTask = nil
        prefetcher.stopPrefetching()
        warmedURLs.removeAll()
        loadedScope = nil
        snapshot = Snapshot()
        preparedSpotlight.removeAll()
        storageError = nil
    }

    func hydrate() {
        activate()
        if ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) == nil,
           !snapshot.rows.isEmpty || snapshot.spotlightUpdatedAt != nil {
            var sections = snapshot.rows.map(\.section)
            for slide in snapshot.spotlight where MediaServerProvider.active != .emby && !sections.contains(where: { $0.id == slide.rowID }) {
                let items = snapshot.spotlight.filter { $0.rowID == slide.rowID }.map(\.item)
                sections.append(ResolvedSection(
                    id: slide.rowID, sectionType: "spotlight", title: slide.rowTitle,
                    featured: false, itemLimit: 20, totalCount: nil,
                    isCustom: nil, customized: nil, items: items
                ))
            }
            ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        }
        if let libraries = snapshot.libraries,
           ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self) == nil {
            ResponseCache.shared.set(libraries, for: CacheKey.userLibraries)
        }
        for (id, detail) in snapshot.details {
            ResponseCache.shared.set(detail, for: CacheKey.itemDetail(id))
        }
    }

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

    func store(_ response: SectionsResponse) {
        activate()
        guard loadedScope != nil else { return }
        let oldURLs = artworkURLs(in: snapshot)
        let oldSlides = Dictionary(snapshot.spotlight.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        let limited = Self.capped(response)
        HomeSectionPreferences.shared.refresh()
        TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: limited.sections)
        let rows = limited.sections.filter { HomeSectionPreferences.shared.isVisible($0.id) }
        let slides = TVHomeSpotlightPreferences.shared.slides(from: limited.sections)
        if snapshot.rows.map(\.section) == rows, snapshot.spotlight == slides,
           snapshot.spotlightUpdatedAt != nil, storageError == nil {
            // Keep failed or evicted artwork and missing details retryable,
            // without rewriting an unchanged snapshot every refresh.
            replaceArtwork(previous: oldURLs)
            enrichSpotlight()
            return
        }
        snapshot.rows = rows.map { Row(section: $0, updatedAt: now) }
        snapshot.spotlight = slides
        snapshot.spotlightUpdatedAt = now
        let slideIDs = Set(snapshot.spotlight.flatMap { Self.detailContentIDs(for: $0.item) })
        snapshot.details = snapshot.details.filter { slideIDs.contains($0.key) }
        for slide in snapshot.spotlight where oldSlides[slide.id] != nil && oldSlides[slide.id] != slide.item {
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
        replaceArtwork(previous: oldURLs)
        persist()
        enrichSpotlight()
    }

    func storeLibraries(_ libraries: LibrariesResponse) {
        activate()
        guard loadedScope != nil else { return }
        snapshot.libraries = libraries
        persist()
    }

    func reconcilePreferences() {
        guard loadedScope != nil else { return }
        HomeSectionPreferences.shared.refresh()
        TVHomeSpotlightPreferences.shared.refresh()
        let oldURLs = artworkURLs(in: snapshot)
        snapshot.rows.removeAll { !HomeSectionPreferences.shared.isVisible($0.section.id) }
        if let ids = TVHomeSpotlightPreferences.shared.selectedRowIDs {
            snapshot.spotlight.removeAll { !ids.contains($0.rowID) }
        }
        let slideIDs = Set(snapshot.spotlight.flatMap { Self.detailContentIDs(for: $0.item) })
        snapshot.details = snapshot.details.filter { slideIDs.contains($0.key) }
        replaceArtwork(previous: oldURLs)
        persist()
    }

    var statuses: [Status] {
        var statuses = [Status(id: Self.spotlightID, title: "Spotlight",
                               count: snapshot.spotlight.count, updatedAt: snapshot.spotlightUpdatedAt)]
        let live: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        let sourceRows = live?.sections ?? snapshot.rows.map(\.section)
        let sections = HomeSectionPreferences.shared.arrangedSections(sourceRows)
            + sourceRows.filter { $0.items.isEmpty && HomeSectionPreferences.shared.isVisible($0.id) }
        for section in sections {
            let row = snapshot.rows.first { $0.section.id == section.id }
            statuses.append(Status(id: section.id, title: section.title,
                                   count: row?.section.items.count ?? 0, updatedAt: row?.updatedAt))
        }
        for row in snapshot.rows where HomeSectionPreferences.shared.isVisible(row.section.id)
            && !statuses.contains(where: { $0.id == row.section.id }) {
            statuses.append(Status(id: row.section.id, title: row.section.title,
                                   count: row.section.items.count, updatedAt: row.updatedAt))
        }
        return statuses
    }

    func clear(_ id: String) {
        activate()
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        generation += 1
        #if os(tvOS)
        cropTasks.values.forEach { $0.cancel() }
        tintTasks.values.forEach { $0.cancel() }
        cropTasks.removeAll()
        tintTasks.removeAll()
        #endif
        enrichmentTask?.cancel()
        enrichmentTask = nil
        let oldURLs = artworkURLs(in: snapshot)
        if id == Self.spotlightID {
            preparedSpotlight.removeAll()
            snapshot.spotlight.removeAll()
            snapshot.spotlightUpdatedAt = nil
            for key in snapshot.details.keys { ResponseCache.shared.remove(CacheKey.itemDetail(key)) }
            snapshot.details.removeAll()
        } else {
            snapshot.rows.removeAll { $0.section.id == id }
        }
        replaceArtwork(previous: oldURLs)
        persist()
    }

    private func artworkURLs(in value: Snapshot) -> Set<URL> {
        var strings: [String] = []
        for row in value.rows {
            let wide = ["continue_watching", "next_up"].contains(row.section.sectionType.lowercased())
            strings += row.section.items.compactMap { wide ? ($0.backdropUrl ?? $0.posterUrl) : $0.posterUrl }
        }
        for slide in value.spotlight {
            strings += [slide.item.backdropUrl, slide.item.posterUrl, slide.item.logoUrl,
                        value.details[slide.id]?.backdropUrl].compactMap { $0 }
        }
        return Set(strings.compactMap { raw in
            guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        })
    }

    private func replaceArtwork(previous: Set<URL>) {
        let desired = artworkURLs(in: snapshot)
        let removed = previous.subtracting(desired)
        let retained = Set(desired.map(\.absoluteString))
        preparedSpotlight = preparedSpotlight.filter { retained.contains($0.key) }
        prefetcher.stopPrefetching(with: Array(warmedURLs.subtracting(desired)))
        PosterImageCache.stopPrefetchingCardArtwork(Array(removed))
        for url in removed {
            VividImagePipeline.shared.cache.removeCachedData(for: VividImageRequest(url: url))
            VividImagePipeline.shared.cache.removeCachedImage(for: VividImageRequest(url: url), caches: .memory)
            VividImagePipeline.shared.cache.removeCachedImage(for: PosterImageCache.cardWarmRequest(for: url), caches: .memory)
        }
        prefetcher.priority = .low
        // Re-queue cache misses too: a failed download or OS eviction must be retryable.
        prefetcher.startPrefetching(with: desired.filter {
            !VividImagePipeline.shared.cache.containsData(for: VividImageRequest(url: $0))
        }.map { VividImageRequest(url: $0, priority: .low) })
        warmedURLs = desired
    }

    /// iOS episode spotlights display their parent series' year and ratings.
    /// Keep that metadata in the same persistent cache as the slide itself.
    static func detailContentIDs(for item: SectionItem) -> [String] {
        #if os(iOS)
        if MediaServerProvider.active == .emby, item.type == "episode",
           let seriesID = item.seriesId, seriesID != item.contentId {
            return [item.contentId, seriesID]
        }
        #endif
        return [item.contentId]
    }

    func spotlightMetadata(for item: SectionItem) -> ItemDetail? {
        guard MediaServerProvider.active == .emby,
              let id = Self.detailContentIDs(for: item).last else { return nil }
        return snapshot.details[id]
    }

    private func enrichSpotlight() {
        enrichmentTask?.cancel()
        let expectedGeneration = generation
        let scope = loadedScope
        var seen = Set<String>()
        let ids = snapshot.spotlight.flatMap { Self.detailContentIDs(for: $0.item) }
            .filter { seen.insert($0).inserted }
        enrichmentTask = Task { @MainActor in
            for id in ids where snapshot.details[id] == nil {
                guard !Task.isCancelled, expectedGeneration == generation, scope == activeScope else { return }
                let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(id))
                let detail: ItemDetail
                if let cached {
                    detail = cached
                } else if let fetched = try? await MetadataRequestPool.shared.itemDetail(contentId: id) {
                    detail = fetched
                } else {
                    continue
                }
                guard !Task.isCancelled, expectedGeneration == generation, scope == activeScope,
                      snapshot.spotlight.contains(where: { Self.detailContentIDs(for: $0.item).contains(id) }) else { return }
                let oldURLs = artworkURLs(in: snapshot)
                snapshot.details[id] = detail
                ResponseCache.shared.set(detail, for: CacheKey.itemDetail(id))
                replaceArtwork(previous: oldURLs)
                persist()
            }
            #if os(tvOS)
            // Prepare only current Spotlight art, sequentially, using the same
            // analysis and persistent records as the visible carousel.
            var urls = Set<String>()
            for slide in snapshot.spotlight {
                for raw in [slide.item.backdropUrl, snapshot.details[slide.item.contentId]?.backdropUrl].compactMap({ $0 }) {
                    guard urls.insert(raw).inserted else { continue }
                    guard !Task.isCancelled, expectedGeneration == generation, scope == activeScope else { return }
                    guard let url = URL(string: raw) else { continue }
                    let record = preparedSpotlight[raw]
                    if record?.cropPrepared != true || record?.cropVersion != 1 {
                        let request = PosterImageCache.displayRequest(url: url, pixelSize: CGSize(width: 768, height: 768), priority: .low)
                        if let image = try? await VividImagePipeline.shared.image(for: request) {
                            guard !Task.isCancelled, expectedGeneration == generation, scope == activeScope else { return }
                            _ = await preparedSpotlightSubject(in: image, url: raw)
                        }
                    }
                    guard !Task.isCancelled, expectedGeneration == generation, scope == activeScope else { return }
                    _ = await preparedSpotlightTint(for: url)
                }
            }
            #endif
        }
    }

    #if os(tvOS)
    func cachedSpotlightTint(for url: URL) -> Color? {
        guard let rgb = preparedSpotlight[url.absoluteString]?.tint, rgb.count == 3 else { return nil }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    func preparedSpotlightSubject(in image: UIImage, url: String) async -> CGRect? {
        if let record = preparedSpotlight[url], record.cropPrepared, record.cropVersion == 1 {
            return record.subject
        }
        let expectedGeneration = generation
        let scope = loadedScope
        let task: Task<CGRect?, Never>
        if let existing = cropTasks[url] {
            task = existing
        } else {
            task = Task.detached(priority: .utility) { TVSpotlightCrop.subject(in: image, key: url) }
            cropTasks[url] = task
        }
        // A disappearing slide must not cancel preparation another slide or
        // the Home cache is awaiting. Account changes cancel the shared tasks.
        let subject = await task.value
        if expectedGeneration == generation { cropTasks.removeValue(forKey: url) }
        guard !Task.isCancelled, expectedGeneration == generation, scope == loadedScope else { return subject }
        updateSpotlightPreparation(url: url) {
            $0.cropVersion = 1
            $0.cropPrepared = true
            $0.subject = subject
        }
        return subject
    }

    func preparedSpotlightTint(for url: URL) async -> Color? {
        if let tint = cachedSpotlightTint(for: url) { return tint }
        let expectedGeneration = generation
        let scope = loadedScope
        let key = url.absoluteString
        let task: Task<Color?, Never>
        if let existing = tintTasks[key] {
            task = existing
        } else {
            task = Task { await HeroBackdropPalette.tintColor(for: url) }
            tintTasks[key] = task
        }
        let result = await task.value
        if expectedGeneration == generation { tintTasks.removeValue(forKey: key) }
        guard let tint = result,
              !Task.isCancelled, expectedGeneration == generation, scope == loadedScope else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if UIColor(tint).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            updateSpotlightPreparation(url: url.absoluteString) { $0.tint = [Double(red), Double(green), Double(blue)] }
        }
        return tint
    }

    private func updateSpotlightPreparation(url: String, update: (inout SpotlightPreparation) -> Void) {
        guard loadedScope != nil, artworkURLs(in: snapshot).contains(where: { $0.absoluteString == url }) else { return }
        var record = preparedSpotlight[url] ?? SpotlightPreparation()
        update(&record)
        guard preparedSpotlight[url] != record else { return }
        preparedSpotlight[url] = record
        persist()
    }
    #endif

    private func persist() {
        guard let scope = loadedScope else { return }
        var value = snapshot
        value.spotlightPreparation = preparedSpotlight.isEmpty ? nil : preparedSpotlight
        let url = fileURL(for: scope)
        writer.async {
            do {
                let data = try JSONEncoder().encode(value)
                guard data.count <= Self.maximumSnapshotBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                Task { @MainActor [weak self] in
                    if self?.loadedScope == scope { self?.storageError = nil }
                }
            } catch {
                Task { @MainActor [weak self] in
                    if self?.loadedScope == scope { self?.storageError = "Couldn’t save the Home cache. It will retry on the next refresh." }
                }
            }
        }
    }
}
#endif
