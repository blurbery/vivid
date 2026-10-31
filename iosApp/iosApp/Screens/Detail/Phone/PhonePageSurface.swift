import SwiftUI

#if !os(tvOS)
/// The canvas behind movie, episode and series pages: the backdrop blurred
/// into glass with a little grain on iPhone, the Duo and iPad, or a dim
/// tint sampled from it.
struct MobileDetailSurface<Content: View>: View {
    let backdropUrl: String?
    let backdropThumbhash: String?
    let isArtworkGlassEnabled: Bool
    @ViewBuilder let content: () -> Content

    @State private var tint = MobileDetailSurface.restingTint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static var restingTint: Color {
        Color(.sRGB, red: 0.04, green: 0.12, blue: 0.14)
    }

    private var showsArtworkGlass: Bool {
        isArtworkGlassEnabled && !reduceTransparency && PhoneDuo.usesPhoneDetailLayout(horizontalSizeClass)
    }

    var body: some View {
        ZStack {
            Color.black
            if showsArtworkGlass, let backdropUrl, !backdropUrl.isEmpty {
                GeometryReader { proxy in
                    AsyncImageView(url: backdropUrl, thumbhash: backdropThumbhash, contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.18)
                        .saturation(1.28)
                        .brightness(-0.10)
                        .blur(radius: 46, opaque: true)
                        .clipped()
                }
                .allowsHitTesting(false)
                Color.black.opacity(0.28)
                tint.opacity(0.10)
                MobileGrainLayer()
            } else {
                tint.opacity(0.42)
            }
            content()
        }
        .ignoresSafeArea()
        .task(id: backdropUrl) {
            guard let backdropUrl, let address = URL(string: backdropUrl) else {
                tint = Self.restingTint
                return
            }
            if let cached = HeroBackdropPalette.cachedTint(for: address) {
                tint = cached
            }
            let sampled = await HeroBackdropPalette.tintColor(for: address)
            guard !Task.isCancelled, let sampled else { return }
            tint = sampled
        }
    }
}

/// Fine film grain tiled over the glass, one tile pixel per device pixel.
private struct MobileGrainLayer: View {
    var body: some View {
        if let tile = MobileGrainTile.image {
            Image(decorative: tile, scale: 3)
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .blendMode(.overlay)
                .opacity(0.012)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A 96 by 96 tile of grey noise from a fixed xorshift sequence, made once.
private enum MobileGrainTile {
    static let image: CGImage? = {
        let side = 96
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 0, count: side * side)
        for index in pixels.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()
}
#endif
