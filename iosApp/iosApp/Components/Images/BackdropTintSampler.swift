import CoreImage
import SwiftUI

/// A dim tint sampled from a backdrop, for gradients behind hero artwork.
enum HeroBackdropPalette {
    /// Keyed by cache scope and URL; lives for the process.
    @MainActor private static var tints: [String: Color] = [:]

    /// Colour management off, so the average is taken on the stored values.
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    @MainActor
    static func cachedTint(for url: URL) -> Color? {
        tints[key(scope: VividCacheScope.artwork, url: url)]
    }

    static func tintColor(for url: URL) async -> Color? {
        let request = PosterImageCache.paletteSampleRequest(for: url)
        guard let image = try? await VividImagePipeline.shared.image(for: request) else { return nil }
        let tint = await Task.detached(priority: .utility) {
            HeroBackdropPalette.sampleTint(of: image)
        }.value
        guard let tint else { return nil }
        let cacheKey = key(scope: request.cacheScope, url: url)
        await MainActor.run { HeroBackdropPalette.tints[cacheKey] = tint }
        return tint
    }

    private static func key(scope: String, url: URL) -> String {
        scope + "|" + url.absoluteString
    }

    private static func sampleTint(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        guard !extent.isEmpty, let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255

        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let target = 0.22
        let scale: Double
        if luminance <= 0.001 {
            scale = 0
        } else if luminance > target {
            scale = target / luminance
        } else {
            scale = max(1, target / max(luminance, 0.05))
        }
        return Color(
            .sRGB,
            red: min(1, red * scale),
            green: min(1, green * scale),
            blue: min(1, blue * scale)
        )
    }
}
