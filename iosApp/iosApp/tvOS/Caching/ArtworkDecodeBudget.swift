import SwiftUI
import UIKit

/// Request shapes, warming and decoded-memory budgets for artwork. Every
/// member is safe to call from any thread.
enum PosterImageCache {
    /// The main screen's scale, never below 1.
    static let displayScale: CGFloat = max(1, UIScreen.main.scale)

    private static let mebibyte = 1_048_576

    /// Card decodes are bounded by this longest edge in pixels.
    private static var cardEdge: Float { Float(320 * displayScale) }

    private static var hasConstrainedMemory: Bool {
        ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
    }

    private static var decodedBudget: (cost: Int, count: Int) {
        #if os(tvOS)
        hasConstrainedMemory ? (96 * mebibyte, 180) : (160 * mebibyte, 280)
        #else
        (256 * mebibyte, 400)
        #endif
    }

    private static let prefetcher: VividImagePrefetcher = {
        let prefetcher = VividImagePrefetcher(
            pipeline: VividImagePipeline.shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 2
        )
        prefetcher.priority = .normal
        return prefetcher
    }()

    /// Registered once, the first time `install()` runs.
    private static let memoryWarningObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
    ) { _ in
        VividImageDiagnostics.shared.count("memory.warning")
        PosterImageCache.trimDecodedMemory()
    }

    static func install() {
        let budget = decodedBudget
        VividImagePipeline.shared = VividImagePipeline(costLimit: budget.cost, countLimit: budget.count)
        _ = memoryWarningObserver
    }

    static func displayRequest(
        url: URL,
        pixelSize: CGSize,
        priority: VividImageRequest.Priority = .normal,
        cacheScope: String = VividCacheScope.artwork,
        softening: Float? = nil
    ) -> VividImageRequest {
        var request = VividImageRequest(url: url, priority: priority, cacheScope: cacheScope)
        request.thumbnail = .init(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
        request.softening = softening
        return request
    }

    static func cardWarmRequest(for url: URL) -> VividImageRequest {
        cardRequest(for: url, cacheScope: VividCacheScope.artwork)
    }

    /// The card-size decode of `url` in a given scope.
    static func cardRequest(for url: URL, cacheScope: String) -> VividImageRequest {
        var request = VividImageRequest(url: url, cacheScope: cacheScope)
        request.thumbnail = .init(maxPixelSize: cardEdge)
        return request
    }

    static func paletteSampleRequest(for url: URL) -> VividImageRequest {
        var request = VividImageRequest(url: url, priority: .low)
        request.thumbnail = .init(maxPixelSize: 64)
        return request
    }

    /// The card-size decode if it is already in memory. Never loads.
    static func warmedCardImage(for url: URL, cacheScope: String = VividCacheScope.artwork) -> PlatformImage? {
        VividImagePipeline.shared.cache[cardRequest(for: url, cacheScope: cacheScope)]?.image
    }

    static func prefetchCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    static func stopPrefetchingCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.stopPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    /// Warms the full-size decode of each URL.
    static func prefetchOriginalArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }

    /// Drops every decoded image from memory; disk copies stay.
    static func trimDecodedMemory() {
        VividImagePipeline.shared.cache.removeAll(caches: .memory)
    }

    static func resetForAccountSwitch() async {
        prefetcher.stopPrefetching()
        await VividImagePipeline.shared.cancelForAccountSwitch()
    }
}

#if os(tvOS)
extension PosterImageCache {
    /// Home holds more decoded artwork while it is browsed.
    static func setHomeBrowsingMemoryBudget(_ enabled: Bool) {
        let cache = VividImagePipeline.shared.cache
        if enabled {
            cache.setMemoryLimits(cost: (hasConstrainedMemory ? 192 : 320) * mebibyte, count: 600)
        } else {
            let budget = decodedBudget
            cache.setMemoryLimits(cost: budget.cost, count: budget.count)
        }
    }

    /// Warms the first eight distinct cast photos of a movie.
    static func prefetchVisibleMovieCast(for detail: ItemDetail) {
        guard detail.type == "movie", let cast = detail.cast else { return }
        var collected: [URL] = []
        var seen = Set<String>()
        for member in cast {
            if collected.count == 8 { break }
            guard let text = member.photoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let url = URL(string: text),
                  seen.insert(url.absoluteString).inserted else { continue }
            collected.append(url)
        }
        prefetchCardArtwork(collected)
    }
}
#endif
