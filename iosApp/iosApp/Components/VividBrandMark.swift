import SwiftUI

/// The silver Vivid mark for sign-in and About pages.
struct VividMarkView: View {
    var width: CGFloat = 150

    var body: some View {
        VStack(spacing: 8) {
            VividLogoView(size: width)
        }
    }
}
