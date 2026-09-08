#if os(tvOS) || os(iOS)
import SwiftUI
import UIKit

struct VividLogoView: View {
    var size: CGFloat
    @Environment(\.displayScale) private var displayScale

    private static let thumbnails = NSCache<NSString, UIImage>()
    private static let artwork = UIImage(named: "VividMarkSilver")

    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Vivid")
    }

    // Downsample to physical pixels before SwiftUI draws the small mark,
    // preserving smooth edges instead of minifying the full-size texture.
    private var thumbnail: UIImage? {
        let pixels = ceil(size * displayScale)
        let key = "\(Int(pixels))" as NSString
        if let cached = Self.thumbnails.object(forKey: key) {
            return cached
        }
        guard let image = Self.artwork?.preparingThumbnail(
            of: CGSize(width: pixels, height: pixels)
        ) else { return Self.artwork }
        Self.thumbnails.setObject(image, forKey: key)
        return image
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
