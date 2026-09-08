import XCTest
import Foundation
@testable import Vivid

final class AIModelDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! decoder().decode(T.self, from: Data(json.utf8))
    }

    func testMetadataAIStatusTolerantOnView() {
        // Known mode.
        let auto = decode(MetadataAIStatus.self, """
        { "enabled": true, "on_view": "auto" }
        """)
        XCTAssertTrue(auto.enabled)
        XCTAssertTrue(auto.onView == .auto)

        // Unknown mode → `.off`.
        let unknown = decode(MetadataAIStatus.self, """
        { "enabled": true, "on_view": "sometimes" }
        """)
        XCTAssertTrue(unknown.onView == .off)

        // Omitted → `.off`, enabled defaults false.
        let empty = decode(MetadataAIStatus.self, "{}")
        XCTAssertFalse(empty.enabled)
        XCTAssertTrue(empty.onView == .off)
    }
}
