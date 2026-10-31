import CryptoKit
import Foundation

enum DiagnosticsSHA256 {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// The first `count` characters of the lowercase hexadecimal SHA-256.
    static func shortHex(data: Data, count: Int = 16) -> String {
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(String(decoding: hex, as: UTF8.self).prefix(count))
    }
}
