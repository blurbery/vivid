import Foundation

/// Replaces identifying URL path segments with `{id}`, so network diagnostics
/// keep the route without the item, profile or file it was for.
enum DiagnosticsPathTemplate {
    static let placeholder = "{id}"

    private static let fileSystemPrefixes = ["/users/", "/private/", "/var/mobile/", "/data/user/"]
    private static let pieceSeparators = CharacterSet(charactersIn: "(),.:;[]")
    private static let idPrefixes = [
        "account", "attempt", "content", "correlation", "device", "file", "item", "library", "media",
        "playback", "plan", "profile", "ps", "req", "request", "run", "server", "session", "subtitle",
        "track", "user",
    ]

    private static let template = regex("^\\{[a-z][a-z0-9_]*\\}$")
    private static let version = regex("^[vV][0-9]+$")
    private static let uuid = regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private static let digits = regex("^[0-9]+$")
    private static let prefixedID = regex("^(?:" + idPrefixes.joined(separator: "|") + ")[_-][A-Za-z0-9_-]{4,}$", caseInsensitive: true)
    private static let longHex = regex("^[0-9a-fA-F]{16,}$")
    private static let opaque = regex("^[A-Za-z0-9_-]{20,}$")
    private static let mixed = regex("^(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{8,}$")

    static func templatedPath(for url: URL) -> String {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            return templatedPath(forRawPath: components.percentEncodedPath)
        }
        return templatedPath(forRawPath: url.path)
    }

    static func templatedPath(forRawPath rawPath: String) -> String {
        let path = rawPath.prefix { $0 != "?" && $0 != "#" }
        let joined = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { isEmissionPrivateSegment(String($0)) ? placeholder : String($0) }
            .joined(separator: "/")
        let lowered = joined.lowercased()
        guard fileSystemPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return joined }
        return joined.split(separator: "/", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, segment in index == 0 && segment.isEmpty ? "" : placeholder }
            .joined(separator: "/")
    }

    static func isEmissionPrivateSegment(_ value: String) -> Bool {
        if value.isEmpty || matches(template, value) || matches(version, value) { return false }
        if value.contains("%") || value == "." || value == ".." { return true }
        let pieces = [value] + value.components(separatedBy: pieceSeparators).filter { !$0.isEmpty }
        return pieces.contains { piece in
            [uuid, digits, prefixedID, longHex, opaque, mixed].contains { matches($0, piece) }
        }
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are fixed, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
