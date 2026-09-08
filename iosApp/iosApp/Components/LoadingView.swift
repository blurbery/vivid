import SwiftUI

/// Full-screen loading indicator.
struct LoadingView: View {
    var message: String? = nil
    var usesPageBackground = false

    var body: some View {
        ZStack {
            if usesPageBackground {
                VividPageBackdrop()
            } else {
                Color.vividBackground.ignoresSafeArea()
            }

            VStack(spacing: 20) {
                VividMarkView(width: 132)

                ProgressView()
                    .tint(.vividOnSurface)
                    .scaleEffect(1.2)

                if let message {
                    Text(message)
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                }
            }
        }
    }
}
