import SwiftUI

struct RefreshStatusPill: View {
    static let minimumVisibleDuration: TimeInterval = 1.5
    var compactGlass = false

    @ViewBuilder
    var body: some View {
        if compactGlass {
            VividLoadingDots(compact: true, dotDiameter: 6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 1, y: 1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .vividGlass(in: Capsule(), tint: .black.opacity(0.35))
                .environment(\.colorScheme, .dark)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Refreshing")
        } else {
            standardPill
        }
    }

    private var standardPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.vividOnSurface)

            Text("Refreshing")
                .font(.vividCaption)
                .fontWeight(.semibold)
                .foregroundColor(.vividOnSurface)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        #if os(iOS)
        .background(Color(white: 0.10), in: Capsule())
        #else
        .background(.ultraThinMaterial, in: Capsule())
        #endif
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing")
    }
}
