#if os(tvOS) || os(iOS)
import SwiftUI

struct VividLogoView: View {
    var size: CGFloat
    var body: some View {
        Image("VividMarkSilver")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Vivid")
    }
}

struct VividCopyrightFooter: View {
    var body: some View {
        Text("© 2026 Vivid™")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.49))
    }
}
#endif
