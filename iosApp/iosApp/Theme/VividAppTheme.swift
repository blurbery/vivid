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
                // Leave the system hosting/navigation background visible.
                // Native adds no app colour, gradient, tint or material.
                Color.clear
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

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
