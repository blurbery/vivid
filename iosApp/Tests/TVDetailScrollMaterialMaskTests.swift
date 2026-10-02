#if os(tvOS)
import SwiftUI
import XCTest
@testable import VividTV

/// The cached band must reproduce the live per-frame blur at every lift.
@MainActor
final class TVDetailScrollMaterialMaskTests: XCTestCase {
    private let viewport = CGSize(width: 1920, height: 1080)

    private func alpha(_ view: some View, scale: CGFloat) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: viewport.width, height: viewport.height))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    func testCachedBandMatchesLiveBlurAcrossScroll() throws {
        // Without a band both masks would render the live fallback and match trivially.
        _ = try XCTUnwrap(TVDetailCurvedBlurBand.band(for: viewport), "The cached band must render for this comparison")
        let maxLift = viewport.height * 1.2
        var report: [String] = []
        for step in 0...6 {
            let lift = maxLift * CGFloat(step) / 6
            let live = try alpha(TVDetailScrollMaterialMask(viewportSize: viewport, lift: lift, usesCachedBand: false), scale: 2)
            let cached = try alpha(TVDetailScrollMaterialMask(viewportSize: viewport, lift: lift), scale: 2)
            XCTAssertEqual(live.count, cached.count)
            let diffs = zip(live, cached).map { abs(Int($0) - Int($1)) }
            let worst = diffs.max() ?? 0
            let mean = Double(diffs.reduce(0, +)) / Double(max(1, diffs.count))
            let over2 = diffs.filter { $0 > 2 }.count
            report.append(String(format: "lift %4.0f: max %d/255, mean %.4f, pixels over 2/255: %d", lift, worst, mean, over2))
            XCTAssertLessThanOrEqual(worst, 2, "lift \(lift)")
        }
        print("TVDetailScrollMaterialMask diff\n" + report.joined(separator: "\n"))
    }
}
#endif
