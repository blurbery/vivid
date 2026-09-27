import SwiftUI

/// App-wide appearance saved on this device, independent of server or profile.
enum VividAppTheme: String, CaseIterable, Identifiable {
    case graphite
    case black
    case native

    // Keep this key stable across app versions. Updates retain the app defaults.
    static let storageKey = "vivid.appearance.theme.v1"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .black: "Black"
        case .native: "Native"
        }
    }
}

/// Static page canvas. Theme changes update the background without replacing
/// navigation content, focus targets, artwork or playback surfaces.
struct VividAppBackdrop: View {
    @AppStorage(VividAppTheme.storageKey, store: .standard) private var theme: VividAppTheme = .graphite

    var body: some View {
        Group {
            switch theme {
            case .graphite:
                graphite
            case .black:
                Color.black
            case .native:
                #if os(iOS)
                nativeTVAppearance
                #else
                // Preserve the native tvOS hosting/navigation background.
                Color.clear
                #endif
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    #if os(iOS)
    /// Reproduce the dark tvOS hosting backdrop on iPhone and iPad, where
    /// transparent content exposes black instead. These sRGB reference colours
    /// follow the tvOS 27 backdrop across a normalised grid, so the appearance
    /// fills portrait and landscape without stretching a bundled screenshot.
    /// Keep this static: changing focus or scrolling must not animate the canvas.
    private var nativeTVAppearance: some View {
        MeshGradient(
            width: 5,
            height: 5,
            points: (0..<5).flatMap { row in
                (0..<5).map { column in
                    SIMD2<Float>(Float(column) / 4, Float(row) / 4)
                }
            },
            colors: Self.nativeTVColours,
            smoothsColors: true,
            colorSpace: .perceptual
        )
    }

    private static let nativeTVColours: [Color] = [
        (49, 57, 66), (49, 56, 63), (49, 53, 61), (51, 56, 60), (56, 54, 56),
        (52, 56, 60), (50, 55, 60), (51, 54, 57), (49, 52, 56), (53, 50, 50),
        (49, 55, 59), (45, 49, 51), (48, 46, 46), (44, 43, 43), (54, 52, 51),
        (44, 42, 36), (41, 39, 32), (37, 38, 36), (40, 43, 41), (49, 48, 44),
        (43, 40, 31), (43, 38, 29), (34, 33, 30), (35, 39, 37), (38, 41, 38),
    ].map { red, green, blue in
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
    #endif

    @ViewBuilder
    private var graphite: some View {
        #if os(iOS)
        ZStack {
            Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
            RadialGradient(
                stops: [
                    .init(color: .white.opacity(0.035), location: 0),
                    .init(color: .white.opacity(0.018), location: 0.36),
                    .init(color: .clear, location: 1),
                ],
                center: UnitPoint(x: 0.46, y: 0.42),
                startRadius: 0,
                endRadius: 520
            )
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.012), location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.045), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        #else
        LinearGradient(
            colors: [
                Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255),
                Color(red: 3 / 255, green: 4 / 255, blue: 5 / 255),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        #endif
    }
}
