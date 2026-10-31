import SwiftUI

#if !os(tvOS)
/// Hero artwork that drifts down and dims as the page scrolls up, fades out
/// at its foot, and on a pull-down stretches to stay attached to the top.
/// Detail pages use it, and so does Home's spotlight.
struct PhoneDetailParallaxArtwork: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat
    let isEnabled: Bool
    let artworkContentMode: ContentMode
    let usesSubjectFraming: Bool
    let coordinateSpaceName: String
    let fadeStart: CGFloat
    let fadeMiddle: CGFloat
    let fadeEnd: CGFloat
    let smoothFade: Bool
    let keepsTopAttached: Bool
    let topShadeOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        url: String?,
        thumbhash: String?,
        height: CGFloat,
        isEnabled: Bool,
        artworkContentMode: ContentMode = .fill,
        usesSubjectFraming: Bool = false,
        coordinateSpaceName: String = "phone-detail-scroll",
        fadeStart: CGFloat = 0.72,
        fadeMiddle: CGFloat = 0.84,
        fadeEnd: CGFloat = 1,
        smoothFade: Bool = false,
        keepsTopAttached: Bool = false,
        topShadeOpacity: Double = 0
    ) {
        self.url = url
        self.thumbhash = thumbhash
        self.height = height
        self.isEnabled = isEnabled
        self.artworkContentMode = artworkContentMode
        self.usesSubjectFraming = usesSubjectFraming
        self.coordinateSpaceName = coordinateSpaceName
        self.fadeStart = fadeStart
        self.fadeMiddle = fadeMiddle
        self.fadeEnd = fadeEnd
        self.smoothFade = smoothFade
        self.keepsTopAttached = keepsTopAttached
        self.topShadeOpacity = topShadeOpacity
    }

    private var parallaxActive: Bool {
        isEnabled && !reduceMotion && PhoneDuo.usesPhoneDetailLayout(horizontalSizeClass)
    }

    var body: some View {
        let active = parallaxActive
        let spaceName = coordinateSpaceName
        let height = height
        let keepsTopAttached = keepsTopAttached
        ZStack {
            artwork
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
                .visualEffect { content, proxy in
                    let pull = Self.pull(proxy.frame(in: .named(spaceName)).minY)
                    return content.offset(y: active ? pull * 0.52 : 0)
                }
            Color.black
                .visualEffect { content, proxy in
                    let pull = Self.pull(proxy.frame(in: .named(spaceName)).minY)
                    return content.opacity(active ? 0.30 * min(max(pull / 360, 0), 1) : 0)
                }
                .allowsHitTesting(false)
            if topShadeOpacity > 0 {
                LinearGradient(
                    colors: [.black.opacity(topShadeOpacity), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .mask { fadeMask }
        .visualEffect { content, proxy in
            let bounce = keepsTopAttached ? max(proxy.frame(in: .scrollView(axis: .vertical)).minY, 0) : 0
            return content
                .scaleEffect(x: 1, y: 1 + bounce / max(height, 1), anchor: .top)
                .offset(y: -bounce)
        }
    }

    /// How far the layer has moved up past the top, up to 540 points.
    private nonisolated static func pull(_ minY: CGFloat) -> CGFloat {
        min(max(-minY, 0), 540)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url, !url.isEmpty {
            if usesSubjectFraming {
                GeometryReader { proxy in
                    TVSpotlightBackdropImage(url: url, size: proxy.size, fillsViewport: true)
                }
            } else {
                AsyncImageView(url: url, thumbhash: thumbhash, contentMode: artworkContentMode)
            }
        } else {
            Color.vividSurface
        }
    }

    private var fadeMask: LinearGradient {
        if smoothFade {
            let span = max(0.001, fadeEnd - fadeStart)
            let stops = (0...64).map { index -> Gradient.Stop in
                let location = CGFloat(index) / 64
                let t = min(max((location - fadeStart) / span, 0), 1)
                let eased = t * t * t * (t * (6 * t - 15) + 10)
                return Gradient.Stop(color: .black.opacity(1 - eased), location: location)
            }
            return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: fadeStart),
                .init(color: .black.opacity(0.76), location: fadeMiddle),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
