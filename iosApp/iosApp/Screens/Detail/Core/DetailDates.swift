import Foundation

/// Release and air dates as detail pages show them. The server sends a
/// plain date or an ISO 8601 date-time; anything else is shown as sent,
/// trimmed.
enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        guard let trimmed = trimmedInput(raw) else { return nil }
        guard let parsed = parse(trimmed) else { return trimmed }
        return (parsed.isCalendarDay ? longDayFormatter : longFormatter).string(from: parsed.date)
    }

    /// Episode cards ask on every redraw, so results are kept by the input
    /// text, "no date" included.
    static func abbreviatedDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw as NSString
        if let kept = abbreviatedCache.object(forKey: key) { return kept.value }
        let result: String?
        if let trimmed = trimmedInput(raw) {
            result = parse(trimmed).map { ($0.isCalendarDay ? mediumDayFormatter : mediumFormatter).string(from: $0.date) }
                ?? trimmed
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

    /// A parsed value: a calendar day, or a moment with a time.
    private struct ParsedDate {
        let date: Date
        let isCalendarDay: Bool
    }

    /// Date-times are read with their offset and shown in the device's time
    /// zone. A plain date is a calendar day: it is read and shown in GMT, so
    /// "2024-05-01" reads 1 May in every time zone.
    private static func parse(_ text: String) -> ParsedDate? {
        if let moment = dateTimeParser.date(from: text) ?? fractionalDateTimeParser.date(from: text) {
            return ParsedDate(date: moment, isCalendarDay: false)
        }
        if let day = fullDateParser.date(from: text) ?? plainDateParser.date(from: text) {
            return ParsedDate(date: day, isCalendarDay: true)
        }
        return nil
    }

    private static let fullDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = .gmt
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
        parser.timeZone = .gmt
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private static let longFormatter = dateFormatter(style: .long, timeZone: .current)
    private static let mediumFormatter = dateFormatter(style: .medium, timeZone: .current)
    private static let longDayFormatter = dateFormatter(style: .long, timeZone: .gmt)
    private static let mediumDayFormatter = dateFormatter(style: .medium, timeZone: .gmt)

    private static func dateFormatter(style: DateFormatter.Style, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter
    }
}
