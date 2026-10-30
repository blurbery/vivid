import SwiftUI

/// What an artwork view shows before its image arrives, and after a failure.
enum ImagePlaceholderStyle {
    /// The thumbhash (or the surface colour), with a film mark on failure.
    case surface
    /// Nothing at all.
    case clear

    var showsErrorIcon: Bool { self == .surface }
}

#if os(tvOS)
extension EnvironmentValues {
    /// When false, artwork views start no new loads and keep what they hold.
    @Entry var tvArtworkLoadingEnabled: Bool = true
}
#endif

/// Server artwork decoded at the size it is drawn, through the shared
/// pipeline. A card-size decode warmed earlier stands in until the exact
/// size is ready.
struct CachedAsyncImage: View {
    let url: String
    var targetSize: CGSize?
    var thumbhash: String?
    var contentMode: ContentMode
    var alignment: Alignment
    var placeholderStyle: ImagePlaceholderStyle
    var onImageLoaded: (() -> Void)?
    var cacheScope: String?
    var softening: Float?
    var isArtworkResident: Bool

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @Environment(\.tvHomeStableRows) private var inStableRows
    @Environment(\.tvHomeRowArtworkGate) private var rowGate
    @Environment(\.tvArtworkLoadingEnabled) private var loadingEnabled
    #endif

    init(
        url: String,
        targetSize: CGSize? = nil,
        thumbhash: String? = nil,
        contentMode: ContentMode = .fill,
        alignment: Alignment = .center,
        placeholderStyle: ImagePlaceholderStyle = .surface,
        onImageLoaded: (() -> Void)? = nil,
        cacheScope: String? = nil,
        softening: Float? = nil,
        isArtworkResident: Bool = true
    ) {
        self.url = url
        self.targetSize = targetSize
        self.thumbhash = thumbhash
        self.contentMode = contentMode
        self.alignment = alignment
        self.placeholderStyle = placeholderStyle
        self.onImageLoaded = onImageLoaded
        self.cacheScope = cacheScope
        self.softening = softening
        self.isArtworkResident = isArtworkResident
    }

    /// Everything that doesn't depend on the drawn size, worked out once
    /// per body so gate and server changes are observed here.
    private struct Source {
        let url: URL?
        let scope: String
        let cardImage: PlatformImage?
        let mayLoad: Bool
        let transaction: Transaction
    }

    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.CachedAsyncImage.body")
        let source = makeSource()
        #if os(tvOS)
        if inStableRows, let targetSize {
            artwork(source, drawSize: targetSize)
                .frame(width: targetSize.width, height: targetSize.height)
        } else {
            GeometryReader { proxy in artwork(source, drawSize: proxy.size) }
        }
        #else
        GeometryReader { proxy in artwork(source, drawSize: proxy.size) }
        #endif
    }

    private func makeSource() -> Source {
        var allowed = isArtworkResident
        var inHomeRow = false
        var loadingSwitch = true
        #if os(tvOS)
        if let rowGate {
            inHomeRow = true
            allowed = allowed && rowGate.enabled
        }
        loadingSwitch = loadingEnabled
        #endif
        let scope = cacheScope ?? VividCacheScope.artwork
        let resolved = allowed ? resolvedURL : nil
        let cardImage = softening == nil
            ? resolved.flatMap { PosterImageCache.warmedCardImage(for: $0, cacheScope: scope) }
            : nil
        let animates = !inHomeRow && !reduceMotion && cardImage == nil
        var transaction = Transaction(animation: animates ? .easeOut(duration: VividTheme.slowDuration) : nil)
        if inHomeRow { transaction.disablesAnimations = true }
        return Source(
            url: resolved,
            scope: scope,
            cardImage: cardImage,
            mayLoad: allowed && loadingSwitch,
            transaction: transaction
        )
    }

    private var resolvedURL: URL? {
        let base = MediaServerProvider.active == .silo
            ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        return SiloAPICompatibility.artworkURL(url, relativeTo: base)
    }

    private func artwork(_ source: Source, drawSize: CGSize) -> some View {
        let decodeSize = targetSize ?? drawSize
        let request = source.url.map {
            PosterImageCache.displayRequest(
                url: $0,
                pixelSize: CGSize(width: decodeSize.width * displayScale, height: decodeSize.height * displayScale),
                cacheScope: source.scope,
                softening: softening
            )
        }
        return VividLazyImage(request: request, transaction: source.transaction, isLoadingEnabled: source.mayLoad) { state in
            if let image = state.image ?? source.cardImage.map({ Image(platformImage: $0) }) {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: drawSize.width, height: drawSize.height, alignment: alignment)
                    .clipped()
                    .transition(.opacity)
                    .onAppear { onImageLoaded?() }
            } else {
                placeholder
                    .frame(width: drawSize.width, height: drawSize.height)
                    .overlay {
                        if state.error != nil, source.mayLoad, placeholderStyle.showsErrorIcon {
                            Image(systemName: "film")
                                .foregroundStyle(Color.vividOnSurface.opacity(0.3))
                        }
                    }
            }
        }
        #if os(tvOS)
        .onChange(of: request) { previous, _ in
            // Home rows let go of decodes they no longer show, so browsing
            // stays inside the row budget. Disk copies stay.
            guard rowGate != nil, let previous else { return }
            let cache = VividImagePipeline.shared.cache
            cache.removeCachedImage(for: previous, caches: .memory)
            cache.removeCachedImage(
                for: PosterImageCache.cardRequest(for: previous.url, cacheScope: previous.cacheScope),
                caches: .memory
            )
        }
        #endif
    }

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderStyle {
        case .surface: ThumbhashImage(thumbhash: thumbhash)
        case .clear: Color.clear
        }
    }
}
