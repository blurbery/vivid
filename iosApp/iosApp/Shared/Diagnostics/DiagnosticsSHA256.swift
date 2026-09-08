#if os(iOS) || os(tvOS)
import CryptoKit
import Foundation

/// Stable, non-reversible identifiers for redacted local logs.
enum DiagnosticsSHA256 {
    static func hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func shortHex(data: Data, count: Int = 16) -> String {
        String(hex(data: data).prefix(count))
    }
}
#endif
