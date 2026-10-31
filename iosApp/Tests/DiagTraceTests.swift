import XCTest
@testable import Vivid

final class DiagTraceTests: XCTestCase {
    /// Verbose lines are never kept, so building their text would be wasted.
    func testSuppressedVerboseLineDoesNotEvaluateItsMessage() {
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "trace"
        }
        DiagTrace.log(.verbose, category: .playback, tag: "Test", message: message())
        XCTAssertEqual(evaluations, 0)
    }
}
