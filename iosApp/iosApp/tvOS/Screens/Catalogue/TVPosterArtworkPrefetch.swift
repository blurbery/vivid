#if os(tvOS)
import SwiftUI

/// Keeps a moving band of poster artwork decoded at display size: it warms
/// the band two at a time and lets go of what scrolls out of it.
@MainActor
final class TVPosterArtworkWindow {
    /// One poster at the exact pixel size a card shows it.
    struct Entry: Hashable {
        let url: URL
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat

        init(url: URL, pixelSize: CGSize) {
            self.url = url
            pixelWidth = pixelSize.width
            pixelHeight = pixelSize.height
        }

        fileprivate var identity: Identity {
            Identity(url: url.absoluteString, width: pixelWidth, height: pixelHeight)
        }

        fileprivate var displayRequest: VividImageRequest {
            PosterImageCache.displayRequest(
                url: url,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                priority: .low
            )
        }
    }

    fileprivate struct Identity: Hashable {
        let url: String
        let width: CGFloat
        let height: CGFloat
    }

    private struct Held {
        let url: URL
        let request: VividImageRequest
    }

    private let prefetcher = VividImagePrefetcher(
        pipeline: VividImagePipeline.shared,
        destination: .memoryCache,
        maxConcurrentRequestCount: 2
    )
    private var held: [Identity: Held] = [:]

    init() {}

    /// Two rows behind the anchor and ten rows in all. The anchor is the
    /// first visible index, else the focused one, else the start.
    nonisolated static func range(
        firstVisible: Int?,
        focusedIndex: Int? = nil,
        itemCount: Int,
        columns: Int
    ) -> Range<Int> {
        let columns = max(1, columns)
        let count = max(0, itemCount)
        let anchor = min(max(firstVisible ?? focusedIndex ?? 0, 0), max(0, count - 1))
        let start = max(0, (anchor / columns - 2) * columns)
        let end = min(count, start + 10 * columns)
        return start..<max(start, end)
    }

    func update(_ entries: [Entry]) {
        var wanted: [Identity: Held] = [:]
        var requests: [VividImageRequest] = []
        for entry in entries {
            let request = entry.displayRequest
            let identity = entry.identity
            if wanted[identity] == nil {
                wanted[identity] = Held(url: entry.url, request: request)
            }
            requests.append(request)
        }

        let cache = VividImagePipeline.shared.cache
        let released = held.filter { wanted[$0.key] == nil }.map(\.value)
        if !released.isEmpty {
            prefetcher.stopPrefetching(with: released.map(\.request))
            for item in released {
                cache.removeCachedImage(for: item.request, caches: .memory)
                cache.removeCachedImage(for: PosterImageCache.cardWarmRequest(for: item.url), caches: .memory)
            }
        }
        held = wanted
        prefetcher.replacePendingPrefetching(with: requests.filter { cache[$0] == nil })
    }

    func clear() {
        prefetcher.stopPrefetching()
        update([])
    }
}
#endif
