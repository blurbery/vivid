import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Centralized native `VividImagePipeline` for the Apple client apps.
///
/// Poster-heavy browse/detail surfaces re-request the same images many times
/// during a session. Stock `AsyncImage` has no persistent cache, which causes
/// visible flicker and re-downloads when the user scrolls back. This pipeline
/// gives us:
///
/// - A decoded memory cache sized for the platform's playback headroom
/// - 1 GB on-disk data cache keyed by URL
/// - ImageIO thumbnail decoding straight to the render size, so a w780
///   poster is never decoded at full resolution just to draw a 176 pt card
/// - A prefetcher the grid can use to warm posters N rows ahead
///
/// The pipeline is installed as the `VividImagePipeline.shared` at first access so
/// every `VividLazyImage` / `VividImagePipeline.shared` caller picks it up automatically.
enum PosterImageCache {
    /// Longest edge, in pixels, of the decode the prefetchers park in the
    /// memory cache for poster, still, cover, and portrait artwork. Sized to
    /// cover every Skyline landing card at the display's native scale
    /// (Apple TV 4K renders at 2x: a 176 pt dense poster is 528 px tall), so
    /// the warmed decode paints at least as sharp as the card's own request.
    /// About 1.1 MB for a 2:3 poster at 2x, so a whole warmed feed still fits
    /// the constrained tvOS budget instead of evicting itself. Library grid
    /// cards are larger and keep their own decode.
    static let cardWarmMaxPixelSize: Float = Float(320 * displayScale)

    /// Native display scale used to turn point sizes into decode pixel sizes
    /// off the main thread. `UITraitCollection.current` reports 0 outside a
    /// UIKit context, so read the screen directly.
    static let displayScale: CGFloat = {
        #if canImport(UIKit)
        return max(1, UIScreen.main.scale)
        #else
        return 2
        #endif
    }()

    /// Longest edge, in pixels, for palette sampling decodes.
    static let paletteSampleMaxPixelSize: Float = 64

    // MARK: - Requests

    /// Display request that decodes directly at `pixelSize` (aspect-fill
    /// cover) through ImageIO's thumbnail path. Decoding at the target size
    /// costs a fraction of the CPU and memory of decoding the full image and
    /// resizing it, and the result needs no separate decompression pass.
    /// ImageIO never upscales, so a small source stays at its native size.
    static func displayRequest(url: URL, pixelSize: CGSize, priority: VividImageRequest.Priority = .normal) -> VividImageRequest {
        var request = VividImageRequest(url: url, priority: priority)
        request.thumbnail = VividImageRequest.ThumbnailOptions(
            size: pixelSize,
            unit: .pixels,
            contentMode: .aspectFill
        )
        return request
    }

    /// The request the prefetchers warm for card artwork. Cards look this key
    /// up synchronously on their first frame (`warmedCardImage(for:)`).
    static func cardWarmRequest(for url: URL) -> VividImageRequest {
        var request = VividImageRequest(url: url)
        request.thumbnail = VividImageRequest.ThumbnailOptions(maxPixelSize: cardWarmMaxPixelSize)
        return request
    }

    /// Cheap request for average-color / palette sampling.
    static func paletteSampleRequest(for url: URL) -> VividImageRequest {
        var request = VividImageRequest(url: url, priority: .low)
        request.thumbnail = VividImageRequest.ThumbnailOptions(maxPixelSize: paletteSampleMaxPixelSize)
        return request
    }

    /// Synchronous memory-cache lookup of a warmed card decode. Cheap
    /// dictionary access, safe to call from a view body.
    static func warmedCardImage(for url: URL) -> PlatformImage? {
        VividImagePipeline.shared.cache[cardWarmRequest(for: url)]?.image
    }

    /// Warm card artwork (posters, stills, covers, portraits, avatars) into
    /// the memory cache at the shared card size.
    static func prefetchCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    static func stopPrefetchingCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.stopPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    #if os(tvOS)
    /// Low-priority exact-size working set for the focused Home row. Home rows
    /// contain 20 cards, so warming the complete row removes the cold boundary
    /// that otherwise appears after card 16. Cached results remain under
    /// the pipeline’s normal memory LRU; only unfinished work from the prior row is
    /// cancelled.
    private static let homeRowCardPrefetchLimit = 20
    private static let homeRowCardPrefetcher: VividImagePrefetcher = {
        let prefetcher = VividImagePrefetcher(
            pipeline: VividImagePipeline.shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 2
        )
        prefetcher.priority = .low
        return prefetcher
    }()
    private struct HomeRowCardWarmKey: Equatable {
        let url: URL
        let pixelSize: CGSize
    }
    @MainActor private static var homeRowCardWarmKeys: [HomeRowCardWarmKey] = []

    @MainActor
    static func warmHomeRowCardArtwork(_ candidates: [URL], pointSize: CGSize) {
        let pixelSize = CGSize(
            width: pointSize.width * displayScale,
            height: pointSize.height * displayScale
        )
        var seen = Set<URL>()
        let keys = candidates
            .filter { seen.insert($0).inserted }
            .prefix(homeRowCardPrefetchLimit)
            .map { HomeRowCardWarmKey(url: $0, pixelSize: pixelSize) }
        guard keys != homeRowCardWarmKeys else { return }

        let stale = homeRowCardWarmKeys.filter { !keys.contains($0) }
        let fresh = keys.filter { !homeRowCardWarmKeys.contains($0) }
        homeRowCardWarmKeys = keys

        if !stale.isEmpty {
            homeRowCardPrefetcher.stopPrefetching(with: stale.map(homeRowCardRequest(for:)))
        }
        if !fresh.isEmpty {
            homeRowCardPrefetcher.startPrefetching(with: fresh.map(homeRowCardRequest(for:)))
        }
    }

    @MainActor
    static func cancelHomeRowCardWarmup() {
        guard !homeRowCardWarmKeys.isEmpty else { return }
        homeRowCardPrefetcher.stopPrefetching(
            with: homeRowCardWarmKeys.map(homeRowCardRequest(for:))
        )
        homeRowCardWarmKeys.removeAll()
    }

    private static func homeRowCardRequest(for key: HomeRowCardWarmKey) -> VividImageRequest {
        displayRequest(url: key.url, pixelSize: key.pixelSize, priority: .low)
    }
    #endif

    /// Warm full-size artwork under its bare-URL key. Only for art whose
    /// consumers read the unprocessed decode synchronously (marquee logos).
    static func prefetchOriginalArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }

    #if os(tvOS)
    /// A movie's cast rail is part of the first detail viewport, but its
    /// portraits used to begin loading only after SwiftUI mounted each card.
    /// Warm just the first screenful through the same shared Nuke pipeline as
    /// the hero artwork. `VividImagePrefetcher` queues these requests and returns
    /// immediately, so detail navigation and first paint never wait on them.
    private static let visibleMovieCastPortraitLimit = 8
    #endif

    private static var memoryWarningObserver: NSObjectProtocol?

    /// Call once at app launch before any SwiftUI view renders.
    static func install() {
        VividImagePipeline.shared = makePipeline()
        installMemoryPressureObserverIfNeeded()
    }

    /// Drop decoded images while preserving the disk cache. Playback is the
    /// only surface where poster reuse is invisible but memory headroom is
    /// tight, especially on 3 GB Apple TV hardware.
    static func trimDecodedMemory() {
        VividImagePipeline.shared.cache.removeAll(caches: .memory)
    }

    #if os(tvOS)
    /// Extra decoded artwork capacity only while the discovery Home is visible.
    static func setHomeBrowsingMemoryBudget(_ enabled: Bool) {
        VividImagePipeline.shared.cache.setMemoryLimits(
            cost: enabled ? (isConstrainedMemoryDevice ? 192 : 320) * 1024 * 1024
                : decodedMemoryCacheBudgetBytes,
            count: enabled ? 600 : decodedImageCountLimit
        )
    }
    #endif

    private static func makePipeline() -> VividImagePipeline {
        VividImagePipeline(costLimit: decodedMemoryCacheBudgetBytes, countLimit: decodedImageCountLimit)
    }

    private static var decodedMemoryCacheBudgetBytes: Int {
        #if os(tvOS)
        return isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 160 * 1024 * 1024
        #else
        return 256 * 1024 * 1024
        #endif
    }

    private static var decodedImageCountLimit: Int {
        #if os(tvOS)
        return isConstrainedMemoryDevice ? 180 : 280
        #else
        return 400
        #endif
    }

    private static var isConstrainedMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
    }

    private static func installMemoryPressureObserverIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            trimDecodedMemory()
        }
        #endif
    }

    /// Shared prefetcher. Grid rows enqueue upcoming poster URLs here to warm
    /// the pipeline before those rows are rendered.
    static let prefetcher: VividImagePrefetcher = {
        let p = VividImagePrefetcher(pipeline: VividImagePipeline.shared, destination: .memoryCache)
        p.priority = .normal
        return p
    }()

    #if os(tvOS)
    /// Prefetch only movie portraits. Series cast lives farther down its page
    /// and deliberately keeps the normal lazy-loading path.
    static func prefetchVisibleMovieCast(for detail: ItemDetail) {
        guard detail.type == "movie", let cast = detail.cast else { return }

        var urls: [URL] = []
        var seen = Set<String>()
        for member in cast {
            guard urls.count < visibleMovieCastPortraitLimit else { break }
            guard let value = member.photoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        prefetchCardArtwork(urls)
    }

    /// Warm the root hero backdrops the marquee will display, decoded at the
    /// exact size `TVRootHeroBackdrop` requests so the first rested backdrop
    /// is a straight memory-cache hit with no second decode.
    static func prefetchHeroBackdrops(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map { heroBackdropRequest(for: $0) })
    }

    /// The exact request `TVRootHeroBackdrop` issues for a hero backdrop, so
    /// a warm decode and the display share one memory-cache key.
    static func heroBackdropRequest(
        for url: URL,
        priority: VividImageRequest.Priority = .normal
    ) -> VividImageRequest {
        let pointSize = TVBackdropArtworkLayout.artworkSize(
            forViewportWidth: TVBackdropArtworkLayout.viewportWidth
        )
        let pixelSize = CGSize(
            width: pointSize.width * displayScale,
            height: pointSize.height * displayScale
        )
        return displayRequest(url: url, pixelSize: pixelSize, priority: priority)
    }

    #endif
}
