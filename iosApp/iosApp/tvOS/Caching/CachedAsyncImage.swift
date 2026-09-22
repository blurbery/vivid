import SwiftUI

/// Native image renderer. Drop-in replacement for the stock
/// `AsyncImageView` that:
///
/// - Reads from the shared `PosterImageCache` pipeline (persistent memory +
///   disk cache)
/// - Decodes straight to the target render size through ImageIO's thumbnail
///   path, so a 780×1170 poster is never held in memory at full resolution
///   (or decoded and then resized on the CPU) just to draw at 176×264
/// - Cross-fades in with the same duration as the rest of the app
/// - Shows a solid surface placeholder that blends with the grid background
struct CachedAsyncImage: View {
    let url: String
    var targetSize: CGSize? = nil
    var thumbhash: String? = nil
    var contentMode: ContentMode = .fill
    /// Placement inside this view's resolved frame. Artwork keeps the
    /// centered default; transparent logos opt into `.bottomLeading` so the
    /// visible mark shares the metadata column's true leading edge.
    var alignment: Alignment = .center
    var placeholderStyle: ImagePlaceholderStyle = .surface
    var onImageLoaded: (() -> Void)? = nil
    var cacheScope: String? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    @Environment(\.tvHomeStableRows) private var stableHomeRows
    @Environment(\.tvHomeRowArtworkGate) private var homeArtworkGate
    #else
    private let artworkLoadingEnabled = true
    #endif

    @ViewBuilder
    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.CachedAsyncImage.body")
        #if os(tvOS)
        if stableHomeRows, let targetSize {
            // Home reserves this exact artwork frame. Avoid a separate
            // geometry observation while first collection cells are measured.
            renderedImage(in: targetSize)
                .frame(width: targetSize.width, height: targetSize.height)
        } else {
            measuredImage
        }
        #else
        measuredImage
        #endif
    }

    private var measuredImage: some View {
        GeometryReader { geometry in renderedImage(in: geometry.size) }
    }

    private var isHomeShelf: Bool {
        #if os(tvOS)
        homeArtworkGate != nil
        #else
        false
        #endif
    }

    private func renderedImage(in size: CGSize) -> some View {
        let resolvedSize = targetSize ?? size
        let imageRequest = request(for: resolvedSize)
        let warmedImage = prefetchedImage()
        let loadAnimation: Animation? = isHomeShelf || reduceMotion || warmedImage != nil
            ? nil
            : .easeOut(duration: VividTheme.slowDuration)
        var transaction = Transaction(animation: loadAnimation)
        transaction.disablesAnimations = isHomeShelf
        return VividLazyImage(
            request: imageRequest,
            transaction: transaction,
            isLoadingEnabled: artworkLoadingEnabled
        ) { state in
            // Cache fallback and exact-size results share one rendered branch.
            // Changing the source bitmap must not replace the Image subtree.
            if let image = state.image ?? warmedImage.map({ Image(platformImage: $0) }) {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(
                        width: size.width,
                        height: size.height,
                        alignment: alignment
                    )
                    .clipped()
                    .transition(.opacity)
                    .onAppear(perform: notifyImageLoaded)
            } else if state.error != nil && artworkLoadingEnabled {
                placeholder(in: size)
                    .overlay {
                        if placeholderStyle.showsErrorIcon {
                            Image(systemName: "film")
                                .foregroundColor(.vividOnSurface.opacity(0.3))
                        }
                    }
            } else {
                placeholder(in: size)
            }
        }
    }

    /// Synchronous memory-cache lookup for the card-size decode the
    /// prefetchers warm. Cheap dictionary access — safe to call from `body`.
    private func prefetchedImage() -> PlatformImage? {
        guard let url = resolvedURL else { return nil }
        return PosterImageCache.warmedCardImage(for: url, cacheScope: cacheScope ?? VividCacheScope.artwork)
    }

    private func notifyImageLoaded() {
        onImageLoaded?()
    }

    // MARK: - Request construction

    private func request(for size: CGSize) -> VividImageRequest? {
        guard let url = resolvedURL else { return nil }
        // Scale by the native display scale so we ask the decoder for the
        // exact pixel dimensions we render at.
        let pixelSize = CGSize(
            width: size.width * displayScale,
            height: size.height * displayScale
        )
        return PosterImageCache.displayRequest(url: url, pixelSize: pixelSize, cacheScope: cacheScope ?? VividCacheScope.artwork)
    }

    private var resolvedURL: URL? {
        let base = MediaServerProvider.active == .silo
            ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        return SiloAPICompatibility.artworkURL(url, relativeTo: base)
    }

    private func placeholder(in size: CGSize) -> some View {
        Group {
            switch placeholderStyle {
            case .surface:
                ThumbhashImage(thumbhash: thumbhash)
            case .clear:
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#if os(tvOS)
/// Episode strips retain the painted image independently of the request gate.
/// Pausing new work must never replace every visible card's image subtree.
struct TVEpisodeArtwork: View {
    let url: String
    let thumbhash: String?
    let size: CGSize
    let isVisible: Bool

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tvArtworkLoadingEnabled) private var loadingEnabled
    @Environment(\.tvHomeRowArtworkGate) private var homeArtworkGate
    @State private var retainedImage: PlatformImage?
    @State private var retainedKey: ImageKey?

    private struct ImageKey: Hashable {
        let url: String
        let width: CGFloat
        let height: CGFloat
    }

    private struct LoadKey: Hashable {
        let image: ImageKey
        let visible: Bool
        let enabled: Bool
    }

    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.TVEpisodeArtwork.body")
        let key = ImageKey(url: url, width: size.width * displayScale, height: size.height * displayScale)
        let base = MediaServerProvider.active == .silo
            ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        let request = SiloAPICompatibility.artworkURL(url, relativeTo: base).map {
            PosterImageCache.displayRequest(url: $0, pixelSize: CGSize(width: key.width, height: key.height))
        }
        let cached = isVisible ? request.flatMap { VividImagePipeline.shared.cache[$0]?.image } : nil
        let image = isVisible ? (retainedKey == key ? retainedImage : nil) ?? cached : nil
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if isVisible {
                ThumbhashImage(thumbhash: thumbhash)
            } else {
                Color.vividSurface
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: LoadKey(image: key, visible: isVisible, enabled: loadingEnabled)) {
            guard isVisible else {
                retainedImage = nil
                retainedKey = nil
                return
            }
            guard retainedKey != key || retainedImage == nil else { return }
            // Cached artwork paints even during a fast scroll. No request or
            // decode is needed, and the image branch keeps the same identity.
            if let cached {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    retainedKey = key
                    retainedImage = cached
                }
                return
            }
            guard loadingEnabled, let request else { return }
            do {
                VividImageDiagnostics.shared.count("episode.taskStarted")
                let loaded = try await withTaskCancellationHandler {
                    try await VividImagePipeline.shared.image(for: request)
                } onCancel: {
                    VividImageDiagnostics.shared.count("episode.taskCancelled")
                }
                guard !Task.isCancelled else { return }
                var transaction = Transaction(animation:
                    homeArtworkGate != nil || reduceMotion ? nil : .easeOut(duration: 0.2))
                transaction.disablesAnimations = homeArtworkGate != nil
                withTransaction(transaction) {
                    retainedKey = key
                    retainedImage = loaded
                }
            } catch {
                // Keep the placeholder; the next visibility/settle change can
                // retry. Cancelled work must never repaint a departed card.
            }
        }
        .onDisappear {
            retainedImage = nil
            retainedKey = nil
        }
    }
}
#endif

#if os(tvOS)
private struct TVArtworkLoadingEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Focusable rows stay mounted offscreen. Their image requests can still
    /// be cancelled independently when the row leaves the vertical viewport.
    var tvArtworkLoadingEnabled: Bool {
        get { self[TVArtworkLoadingEnabledKey.self] }
        set { self[TVArtworkLoadingEnabledKey.self] = newValue }
    }
}
#endif

enum ImagePlaceholderStyle {
    case surface
    case clear

    var showsErrorIcon: Bool {
        switch self {
        case .surface:
            return true
        case .clear:
            return false
        }
    }
}
