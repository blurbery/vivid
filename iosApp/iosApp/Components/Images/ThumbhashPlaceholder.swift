import CoreGraphics
import Foundation
import SwiftUI

/// A blurred stand-in decoded from a ThumbHash, or the surface colour when
/// there is no usable hash. Takes whatever frame the caller gives it.
struct ThumbhashImage: View {
    let thumbhash: String?

    @State private var decoded: Decoded?

    private struct Decoded {
        let hash: String
        let image: PlatformImage
    }

    init(thumbhash: String?) {
        self.thumbhash = thumbhash
    }

    private var hashInUse: String? {
        guard let text = thumbhash?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.ThumbhashImage.body")
        let hash = hashInUse
        Group {
            if let decoded, decoded.hash == hash {
                Image(platformImage: decoded.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Color.vividSurfaceVariant
            }
        }
        .task(id: hash) {
            guard let hash else {
                decoded = nil
                return
            }
            let image = await ThumbhashImageStore.shared.image(for: hash)
            guard let image, !Task.isCancelled else { return }
            decoded = Decoded(hash: hash, image: image)
        }
    }
}

/// Decoded placeholders, kept off the main actor. A hash that fails to decode
/// is remembered as a failure so it is never decoded twice.
private actor ThumbhashImageStore {
    static let shared = ThumbhashImageStore()

    private final class Entry {
        let image: PlatformImage?
        init(image: PlatformImage?) { self.image = image }
    }

    private let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    func image(for hash: String) -> PlatformImage? {
        let key = hash as NSString
        if let entry = entries.object(forKey: key) { return entry.image }
        let image = ThumbhashImage.decodePixels(hash).flatMap(Self.makeImage)
        entries.setObject(Entry(image: image), forKey: key)
        return image
    }

    private static func makeImage(_ pixels: ThumbhashImage.DecodedPixels) -> PlatformImage? {
        var bytes = pixels.rgba
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha < 255 else { continue }
            for channel in index..<(index + 3) {
                bytes[channel] = UInt8(Int(bytes[channel]) * alpha / 255)
            }
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: pixels.width,
                height: pixels.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .perceptual
              ) else { return nil }
        return PlatformImage.vividImage(cgImage: cgImage)
    }
}
