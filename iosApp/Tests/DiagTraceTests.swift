import XCTest
@testable import Vivid

/// Suppressed tracing must not evaluate expensive player or network data.
final class DiagTraceTests: XCTestCase {

    func testSuppressedVerboseLineDoesNotEvaluateItsMessage() {
        // Verbose call sites are high-frequency by definition; the autoclosure
        // is what keeps a disabled tier free, so its laziness is behavior.
        var evaluations = 0
        func expensiveMessage() -> String {
            evaluations += 1
            return "trace"
        }

        DiagTrace.log(
            .verbose,
            category: .playback,
            tag: "Test",
            message: expensiveMessage()
        )

        XCTAssertEqual(evaluations, 0)
    }
}
