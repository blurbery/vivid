import CoreImage
import ImageIO
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

    /// The artwork's main colour for the Apple TV Spotlight, at the same dim
    /// level as `tintColor(for:)`. Uses the same small image load, but
    /// isn't shared with the detail pages' cache.
    static func spotlightTintColor(for url: URL) async -> Color? {
        let request = PosterImageCache.paletteSampleRequest(for: url)
        guard let image = try? await VividImagePipeline.shared.image(for: request) else { return nil }
        return await Task.detached(priority: .utility) {
            HeroBackdropPalette.dominantTint(of: image) ?? HeroBackdropPalette.sampleTint(of: image)
        }.value
    }

    /// A plain average mixes an image's hues into a muddy grey (teal and
    /// orange average to brown), so this finds the hue with the most colour
    /// in it and averages only the pixels near that hue. An image with
    /// little colour leans back towards its plain average, so black and
    /// white artwork stays neutral.
    static func dominantTint(of image: UIImage) -> Color? {
        image.cgImage.flatMap(dominantTint(of:))
    }

    /// The main colour for Apple TV's Adaptive theme mode, for any card that
    /// takes focus. Unlike `spotlightTintColor(for:)` it keeps nothing in the
    /// shared decoded-image cache, so browsing never pushes out the posters
    /// on screen: it reads the bytes the card already downloaded and makes
    /// its own small thumbnail off the main thread.
    static func adaptiveTintColor(for url: URL) async -> Color? {
        let request = PosterImageCache.paletteSampleRequest(for: url)
        guard let data = try? await VividImagePipeline.shared.data(for: request) else { return nil }
        return await Task.detached(priority: .utility) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 48,
                  ] as CFDictionary) else { return nil }
            return HeroBackdropPalette.dominantTint(of: thumbnail)
        }.value
    }

    static func dominantTint(of source: CGImage) -> Color? {
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, 48 / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let binCount = 24
        var binWeight = [Double](repeating: 0, count: binCount)
        var binRed = binWeight, binGreen = binWeight, binBlue = binWeight
        var sumRed = 0.0, sumGreen = 0.0, sumBlue = 0.0
        let count = width * height
        for index in 0..<count {
            let red = Double(pixels[index * 4]) / 255
            let green = Double(pixels[index * 4 + 1]) / 255
            let blue = Double(pixels[index * 4 + 2]) / 255
            sumRed += red; sumGreen += green; sumBlue += blue
            let high = max(red, green, blue), low = min(red, green, blue)
            let chroma = high - low
            // Near-black and near-grey pixels carry no reliable hue.
            guard chroma > 0.05, high > 0.1 else { continue }
            var hue: Double
            if high == red {
                hue = (green - blue) / chroma
            } else if high == green {
                hue = (blue - red) / chroma + 2
            } else {
                hue = (red - green) / chroma + 4
            }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            binWeight[bin] += chroma
            binRed[bin] += red * chroma
            binGreen[bin] += green * chroma
            binBlue[bin] += blue * chroma
        }

        // The strongest run of three neighbouring hue bins (about 45 degrees).
        var best = 0, bestWeight = 0.0
        for start in 0..<binCount {
            let weight = (0..<3).reduce(0.0) { $0 + binWeight[(start + $1) % binCount] }
            if weight > bestWeight { best = start; bestWeight = weight }
        }
        let averageRed = sumRed / Double(count)
        let averageGreen = sumGreen / Double(count)
        let averageBlue = sumBlue / Double(count)
        guard bestWeight > 0 else {
            return dimmed(red: averageRed, green: averageGreen, blue: averageBlue)
        }
        var red = 0.0, green = 0.0, blue = 0.0
        for offset in 0..<3 {
            let bin = (best + offset) % binCount
            red += binRed[bin]; green += binGreen[bin]; blue += binBlue[bin]
        }
        red /= bestWeight; green /= bestWeight; blue /= bestWeight

        // How much of the image carries that colour, as mean chroma per pixel.
        let coverage = bestWeight / Double(count)
        let edge = min(1, max(0, (coverage - 0.015) / (0.08 - 0.015)))
        let strength = edge * edge * (3 - 2 * edge)
        let mixedRed = averageRed + (red - averageRed) * strength
        let mixedGreen = averageGreen + (green - averageGreen) * strength
        let mixedBlue = averageBlue + (blue - averageBlue) * strength
        // Brighten to full first, so dimming a dark, saturated colour can't
        // clip a channel and shift its hue.
        let peak = max(mixedRed, mixedGreen, mixedBlue)
        guard peak > 0.001 else { return dimmed(red: 0, green: 0, blue: 0) }
        return dimmed(red: mixedRed / peak, green: mixedGreen / peak, blue: mixedBlue / peak)
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
        return dimmed(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    /// Scales a colour to the shared dim level the hero gradients start from.
    private static func dimmed(red: Double, green: Double, blue: Double) -> Color {
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
