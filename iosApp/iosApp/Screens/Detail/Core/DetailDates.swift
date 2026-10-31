import Foundation

/// Release and air dates as detail pages show them. The server sends a
/// plain date or an ISO 8601 date-time; anything else is shown as sent,
/// trimmed.
enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        guard let trimmed = trimmedInput(raw) else { return nil }
        guard let day = parse(trimmed) else { return trimmed }
        return longFormatter.string(from: day)
    }

    /// Episode cards ask on every redraw, so results are kept by the input
    /// text, "no date" included.
    static func abbreviatedDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw as NSString
        if let kept = abbreviatedCache.object(forKey: key) { return kept.value }
        let result: String?
        if let trimmed = trimmedInput(raw) {
            result = parse(trimmed).map { mediumFormatter.string(from: $0) } ?? trimmed
        } else {
            result = nil
        }
        abbreviatedCache.setObject(CachedText(result), forKey: key)
        return result
    }

    private final class CachedText {
        let value: String?
        init(_ value: String?) { self.value = value }
    }

    private static let abbreviatedCache: NSCache<NSString, CachedText> = {
        let cache = NSCache<NSString, CachedText>()
        cache.countLimit = 2_000
        return cache
    }()

    private static func trimmedInput(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Every value is shown as the calendar day the server wrote. A
    /// date-time is cut to its date part, and both are read and shown in GMT,
    /// so "2024-05-01" and "2024-05-01T23:30:00Z" read 1 May in every time
    /// zone (Emby and Jellyfin send premiere dates as midnight GMT
    /// date-times).
    private static func parse(_ text: String) -> Date? {
        fullDateParser.date(from: text) ?? plainDateParser.date(from: text)
    }

    private static let fullDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = .gmt
        return parser
    }()

    private static let plainDateParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .gmt
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private static let longFormatter = dateFormatter(style: .long)
    private static let mediumFormatter = dateFormatter(style: .medium)

    private static func dateFormatter(style: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .gmt
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter
    }
}
