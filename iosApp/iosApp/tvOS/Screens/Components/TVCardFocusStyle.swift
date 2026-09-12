#if os(tvOS)
import SwiftUI

struct TVWatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color(red: 0.16, green: 0.62, blue: 0.34), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .accessibilityLabel("Watched")
    }
}

#endif
