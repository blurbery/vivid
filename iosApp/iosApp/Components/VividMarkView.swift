import SwiftUI

struct VividMarkView: View {
    var width: CGFloat = 150
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image("VividMarkSilver")
                .resizable()
                .scaledToFit()
                .frame(width: width)
                .accessibilityLabel("Vivid")

            if let subtitle {
                Text(subtitle)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
                    .tracking(2)
            }
        }
    }
}
