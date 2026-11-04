import ImageIO
import SwiftUI

/// A brand's TMDb logo as a white silhouette, so every tile reads the same on
/// the dark cards. Falls back to the brand name as a wordmark.
struct StudioNetworkLogo: View {
    let brand: StudioNetworkBrand?
    let url: URL?
    var fallbackName = ""

    private var name: String { brand?.name ?? fallbackName }
    private var usesWordmark: Bool { brand?.usesWordmark == true }

    var body: some View {
        if brand?.stacksLogoWords == true, let url {
            StackedWordsLogo(url: url) { standardLogo }.accessibilityHidden(true)
        } else {
            standardLogo
        }
    }

    private var standardLogo: some View {
        AsyncImage(url: usesWordmark ? nil : url) { phase in
            if let image = phase.image {
                if brand?.knocksOutLogoText == true {
                    ZStack {
                        silhouette(image)
                        image.resizable().scaledToFit()
                            .saturation(0).contrast(3)
                            .luminanceToAlpha()
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                } else {
                    silhouette(image)
                }
            } else if usesWordmark {
                wordmark
            } else {
                Text(name)
                    .font(.system(size: 200, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.05)
            }
        }
        .accessibilityHidden(true)
    }

    /// Drawn once at display size and scaled like the TMDb logos, so it
    /// matches their weight and keeps the same letter spacing on every tile.
    /// Scaling the text itself kept its tracking in points, which crowded the
    /// letters on the smaller iPhone tiles.
    @ViewBuilder
    private var wordmark: some View {
        if let image = Self.wordmarkImage(name) {
            silhouette(image)
        }
    }

    private func silhouette(_ image: Image) -> some View {
        image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
    }

    @MainActor private static var wordmarks: [String: Image] = [:]

    @MainActor private static func wordmarkImage(_ name: String) -> Image? {
        if let image = wordmarks[name] { return image }
        // The slightly tight tracking of a display wordmark. Tracking also
        // trims after the last letter, so trailing padding keeps it whole.
        let renderer = ImageRenderer(content: Text(name)
            .font(.system(size: 200, weight: .semibold))
            .tracking(-13)
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.trailing, 13))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = Image(decorative: cgImage, scale: 2)
        wordmarks[name] = image
        return image
    }
}

/// A one-line logo with its emblem on the left, the first word on top and the
/// second word below, scaled to the first word's width. Shows the logo as it
/// is if it doesn't split into an emblem and two words, and the standard logo
/// while the stacked one loads or if it can't be built.
private struct StackedWordsLogo<Fallback: View>: View {
    let url: URL
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
            } else {
                fallback()
            }
        }
        .task(id: url) { image = await StackedWordsLogoRenderer.image(for: url) }
    }
}

@MainActor
private enum StackedWordsLogoRenderer {
    private static var images: [URL: Image] = [:]

    static func image(for url: URL) async -> Image? {
        if let image = images[url] { return image }
        // The 500-point logo's letters are only a few pixels apart, so the
        // stacked version is built from the full-size original.
        let original = URL(string: url.absoluteString.replacingOccurrences(of: "/t/p/w500/", with: "/t/p/original/")) ?? url
        guard let (data, _) = try? await URLSession.shared.data(from: original),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let stacked = await Task.detached(priority: .utility) { LogoStacker(logo)?.stacked() }.value
        let image = Image(decorative: stacked ?? logo, scale: 1)
        images[url] = image
        return image
    }
}

/// Splits a logo into ink columns and redraws it with the words stacked.
private struct LogoStacker {
    private typealias Piece = (image: CGImage, size: CGSize)

    private let logo: CGImage
    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init?(_ logo: CGImage) {
        let width = logo.width, height = logo.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(logo, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.logo = logo
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func stacked() -> CGImage? {
        // Letters sit close together; the gaps after the emblem and between
        // the words are wider than about a third of the letter height.
        let runs = inkRuns()
        guard runs.count >= 3, let letter = rows(in: runs[1]) else { return nil }
        var groups = [runs[0]]
        for run in runs.dropFirst() {
            let previous = groups[groups.count - 1]
            if Double(run.lowerBound - previous.upperBound) > Double(letter.count) * 0.29 {
                groups.append(run)
            } else {
                groups[groups.count - 1] = previous.lowerBound...run.upperBound
            }
        }
        guard groups.count == 3,
              let emblem = crop(groups[0]), let top = crop(groups[1]), let bottom = crop(groups[2]) else { return nil }

        let bottomHeight = bottom.size.height * top.size.width / bottom.size.width
        let gap = top.size.height * 0.28
        let stackHeight = top.size.height + gap + bottomHeight
        let emblemWidth = emblem.size.width * stackHeight / emblem.size.height
        let textX = emblemWidth + top.size.height * 0.32
        guard let output = CGContext(data: nil, width: Int((textX + top.size.width).rounded(.up)),
                                     height: Int(stackHeight.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        output.interpolationQuality = .high
        output.draw(emblem.image, in: CGRect(x: 0, y: 0, width: emblemWidth, height: stackHeight))
        output.draw(top.image, in: CGRect(x: textX, y: bottomHeight + gap, width: top.size.width, height: top.size.height))
        output.draw(bottom.image, in: CGRect(x: textX, y: 0, width: top.size.width, height: bottomHeight))
        return output.makeImage()
    }

    private func ink(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 40 }

    /// Runs of columns with ink: the emblem, then each letter. A single blank
    /// column doesn't end a run.
    private func inkRuns() -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var last = 0
        for x in 0..<width {
            if (0..<height).contains(where: { ink(x, $0) }) {
                if start == nil { start = x }
                last = x
            } else if let first = start, x - last > 1 {
                runs.append(first...last)
                start = nil
            }
        }
        if let first = start { runs.append(first...last) }
        return runs
    }

    /// The rows with ink in `columns`.
    private func rows(in columns: ClosedRange<Int>) -> ClosedRange<Int>? {
        var top = height, bottom = -1
        for y in 0..<height where columns.contains(where: { ink($0, y) }) {
            top = min(top, y)
            bottom = max(bottom, y)
        }
        return bottom >= top ? top...bottom : nil
    }

    private func crop(_ columns: ClosedRange<Int>) -> Piece? {
        guard let rows = rows(in: columns) else { return nil }
        let rect = CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
        return logo.cropping(to: rect).map { ($0, rect.size) }
    }
}
