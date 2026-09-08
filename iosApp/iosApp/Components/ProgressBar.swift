import SwiftUI

struct ResumeProgressBar: View {
    let value: Double
    #if os(tvOS)
    var height: CGFloat = 8
    var inset: CGFloat = 20
    #else
    var height: CGFloat = 5
    var inset: CGFloat = 14
    #endif

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.35)
                Color.white
                    .frame(width: geometry.size.width * (value.isFinite ? min(max(value, 0), 1) : 0))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A thin progress bar (0-1) for showing watch progress.
/// Uses white fill on translucent track (Plezy style — no accent color).
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 3)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.vividOnSurface)
                    .frame(width: geo.size.width * min(max(value, 0), 1), height: 3)
            }
        }
        .frame(height: 3)
    }
}
