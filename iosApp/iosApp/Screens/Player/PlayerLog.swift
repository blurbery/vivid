import Foundation

/// Writes a `[CMP-…]` player trace line to the console, and through
/// `DiagTrace` to the local Apple log (redacted, essential or verbose).
@inline(__always)
func cmpLog(_ message: @autoclosure () -> String, verbose: Bool = false) {
    let rendered = message()
    print(rendered)
    #if os(iOS) || os(tvOS)
    DiagTrace.log(
        verbose ? .verbose : .essential,
        level: .info,
        category: .playback,
        tag: "CMP",
        message: rendered
    )
    #endif
}
