#if os(iOS) || os(tvOS)
import Foundation

/// Removes identifying URL path segments before local logging.
enum DiagnosticsPathTemplate {
    static let placeholder = "{id}"


    static func templatedPath(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return templatedPath(forRawPath: url.path)
        }
        return templatedEmissionPath(components.percentEncodedPath)
    }

    static func templatedPath(forRawPath rawPath: String) -> String {
        let pathOnly = rawPath.prefix { $0 != "?" && $0 != "#" }
        return templatedEmissionPath(String(pathOnly))
    }

    static func isEmissionPrivateSegment(_ value: String) -> Bool {
        if value.isEmpty { return false }
        if matches(templateSegmentRegex, value) || matches(safeVersionSegmentRegex, value) {
            return false
        }
        if value.contains("%") || value == "." || value == ".." { return true }
        let candidates = [value] + value.components(separatedBy: candidateSeparators)
        return candidates.contains { candidate in
            !candidate.isEmpty && (
                matches(unanchoredUUIDRegex, candidate)
                    || matches(numericSegmentRegex, candidate)
                    || matches(privateIDSegmentRegex, candidate)
                    || matches(hexSegmentRegex, candidate)
                    || matches(opaqueSegmentRegex, candidate)
                    || matches(alphanumericIDSegmentRegex, candidate)
            )
        }
    }

    private static func templatedEmissionPath(_ path: String) -> String {
        let templated = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let candidate = String(segment)
                return isEmissionPrivateSegment(candidate) ? placeholder : candidate
            }
            .joined(separator: "/")
        return templatingReservedLeadingSegment(of: templated)
    }

    private static func templatingReservedLeadingSegment(of path: String) -> String {
        let lowercased = path.lowercased()
        let reservedPrefixes = ["/users/", "/private/", "/var/mobile/", "/data/user/"]
        guard reservedPrefixes.contains(where: lowercased.hasPrefix) else { return path }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, segment in
                index == 0 && segment.isEmpty ? "" : placeholder
            }
        return segments.joined(separator: "/")
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static let candidateSeparators = CharacterSet(charactersIn: ".,;:()[]")


    private static let unanchoredUUIDRegex = try! NSRegularExpression(
        pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
    )
    private static let numericSegmentRegex = try! NSRegularExpression(
        pattern: #"^[0-9]+$"#
    )
    private static let hexSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^[0-9a-f]{16,}$"#
    )
    private static let opaqueSegmentRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9_-]{20,}$"#
    )
    private static let privateIDSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#
    )
    private static let alphanumericIDSegmentRegex = try! NSRegularExpression(
        pattern: #"^(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{8,}$"#
    )
    private static let templateSegmentRegex = try! NSRegularExpression(
        pattern: #"^\{[a-z][a-z0-9_]*\}$"#
    )
    private static let safeVersionSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^v[0-9]+$"#
    )
}
#endif
