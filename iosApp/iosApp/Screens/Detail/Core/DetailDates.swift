import Foundation

/// Release and air dates as detail pages show them. The server sends a
/// plain date or an ISO 8601 date-time; anything else is shown as sent.
enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        guard let trimmed = trimmedInput(raw) else { return nil }
        guard let date = parse(trimmed) else { return trimmed }
        return longFormatter.string(from: date)
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

    /// The ISO 8601 forms read in GMT; the plain pattern reads in the
    /// device's time zone.
    private static func parse(_ text: String) -> Date? {
        fullDateParser.date(from: text)
            ?? dateTimeParser.date(from: text)
            ?? fractionalDateTimeParser.date(from: text)
            ?? plainDateParser.date(from: text)
    }

    private static let fullDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser
    }()

    private static let dateTimeParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    private static let fractionalDateTimeParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let plainDateParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let mediumFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
