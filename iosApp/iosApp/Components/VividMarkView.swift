import SwiftUI

struct VividMarkView: View {
    var width: CGFloat = 150
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            #if os(iOS) || os(tvOS)
            VividLogoView(size: width)
            #endif

            if let subtitle {
                Text(subtitle)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
                    .tracking(2)
            }
        }
    }
}
