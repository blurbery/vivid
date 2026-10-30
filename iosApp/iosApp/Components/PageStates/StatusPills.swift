import SwiftUI

/// Small glass dots shown while a page refreshes in the background.
struct RefreshStatusPill: View {
    /// Keeps the indicator up long enough to read as a refresh, not a flicker.
    static let minimumVisibleDuration: TimeInterval = 1.5

    var compactGlass: Bool = false

    var body: some View {
        VividLoadingDots(compact: true, dotDiameter: 6)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .vividGlass(in: Capsule(), tint: Color.black.opacity(0.35))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Refreshing"))
    }
}

/// Shown over cached content while the server can't be reached.
struct ServerUnreachablePill: View {
    init() {}

    var body: some View {
        let isOnline = ConnectionMonitor.shared.isDeviceOnline
        HStack(spacing: 10) {
            Image(systemName: isOnline ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)
            visibleText(isOnline: isOnline)
                .font(.vividCaption.weight(.semibold))
                .foregroundStyle(Color.vividOnSurface)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background { background }
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText(isOnline: isOnline))
    }

    private func visibleText(isOnline: Bool) -> Text {
        isOnline
            ? Text("Can't reach server \u{2014} showing cached content")
            : Text("You're offline \u{2014} showing cached content")
    }

    // Offline, the pill speaks what it shows.
    private func spokenText(isOnline: Bool) -> Text {
        isOnline ? Text("Can't reach the server. Showing cached content.") : visibleText(isOnline: false)
    }

    @ViewBuilder
    private var background: some View {
        #if os(tvOS)
        Capsule().fill(.ultraThinMaterial)
        #else
        Capsule().fill(Color(white: 0.10))
        #endif
    }
}
