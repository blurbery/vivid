import XCTest
@testable import Vivid

/// The fixtures were made by version 1.1.0 of the Go ThumbHash encoder
/// (go.n16f.net/thumbhash).
final class ThumbhashDecodingTests: XCTestCase {
    /// 21 bytes: no alpha, encoded count 5, portrait, so a 5 by 7 grid.
    private let opaqueHash = "1QcSHQRnh493V4dIh4eXh1h4kJUI"
    /// 25 bytes: alpha, encoded count 5, portrait, so a 5 by 5 grid.
    private let alphaHash = "X5qGNQw7oElslqhGWfSE+Q6oJ1h2iHB2Rw=="

    private func alphaBytes(_ pixels: ThumbhashImage.DecodedPixels) -> [UInt8] {
        stride(from: 3, to: pixels.rgba.count, by: 4).map { pixels.rgba[$0] }
    }

    func testOpaqueHashIsSizedFromItsGrid() throws {
        let pixels = try XCTUnwrap(ThumbhashImage.decodePixels(opaqueHash))
        XCTAssertEqual(pixels.width, 23)
        XCTAssertEqual(pixels.height, 32)
        XCTAssertEqual(pixels.rgba.count, 23 * 32 * 4)
        XCTAssertTrue(alphaBytes(pixels).allSatisfy { $0 == 255 })
    }

    func testHashWithTransparencyKeepsItsAlpha() throws {
        let pixels = try XCTUnwrap(ThumbhashImage.decodePixels(alphaHash))
        XCTAssertEqual(pixels.width, 32)
        XCTAssertEqual(pixels.height, 32)
        XCTAssertEqual(pixels.rgba.count, 32 * 32 * 4)
        let alpha = alphaBytes(pixels)
        XCTAssertTrue(alpha.contains { $0 < 255 })
        XCTAssertTrue(alpha.contains { $0 > 0 })
    }

    func testMalformedInputGivesNothing() throws {
        let opaqueBytes = [UInt8](try XCTUnwrap(Data(base64Encoded: opaqueHash)))
        let inputs = [
            "",
            "not base64",
            Data([1, 2, 3, 4]).base64EncodedString(),
            Data(opaqueBytes.dropLast()).base64EncodedString(),
            Data(opaqueBytes + [0]).base64EncodedString()
        ]
        for input in inputs {
            XCTAssertNil(ThumbhashImage.decodePixels(input), "Expected nil for \(input)")
        }
    }

    func testHeaderLimitsGiveNothing() {
        // The alpha flag needs a sixth byte, and the luminance count can't be 0.
        XCTAssertNil(ThumbhashImage.decodePixels(Data([0, 0, 0x80, 1, 0]).base64EncodedString()))
        XCTAssertNil(ThumbhashImage.decodePixels(Data([0, 0, 0, 0, 0]).base64EncodedString()))
    }

    func testSizeComesFromTheRaisedGrid() throws {
        // Portrait, no alpha, encoded count 1: a 3 by 7 grid, 24 coefficients.
        let bytes: [UInt8] = [0, 0, 0, 1, 0] + Array(repeating: 0, count: 12)
        let pixels = try XCTUnwrap(ThumbhashImage.decodePixels(Data(bytes).base64EncodedString()))
        XCTAssertEqual(pixels.width, 14)
        XCTAssertEqual(pixels.height, 32)
    }
}
