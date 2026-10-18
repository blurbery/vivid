import Foundation

enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        formattedDate(raw, formatter: longDisplayFormatter)
    }

    static func abbreviatedDate(_ raw: String?) -> String? {
        // Episode cards format the same air dates on every redraw, so results
        // are cached per string.
        guard let raw else { return nil }
        let key = raw as NSString
        if let cached = abbreviatedDateCache.object(forKey: key) {
            return cached.length == 0 ? nil : cached as String
        }
        let value = formattedDate(raw, formatter: abbreviatedDisplayFormatter)
        abbreviatedDateCache.setObject((value ?? "") as NSString, forKey: key)
        return value
    }

    /// The calendar day a server release or air date names.
    ///
    /// These are days, not instants. Jellyfin, Emby and Remux send them as
    /// midnight UTC (`2010-05-20T00:00:00.0000000Z`) and Silo as `2010-05-20`,
    /// so a value at midnight keeps the day it names wherever the viewer is.
    /// Jellyfin's TMDB episode provider converts the server's local midnight
    /// to UTC instead (`2024-03-04T13:00:00.0000000Z` from a UTC+11 server),
    /// so any other time is an instant and takes the viewer's day, which is
    /// the server's day when they share a time zone.
    static func calendarDay(_ raw: String, timeZone: TimeZone = .current) -> DateComponents? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(midnightPattern, value) {
            return literalDay(value)
        }
        if let instant = rfc3339Parser.date(from: value) ?? rfc3339FractionalParser.date(from: value) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.dateComponents([.year, .month, .day], from: instant)
        }
        // Anything else that starts with a day, such as Jellyfin's times with
        // milliseconds and no offset, keeps that day.
        return literalDay(value)
    }

    /// Whether the day a server date names has arrived for the viewer, or nil
    /// when the value isn't a date.
    static func dayHasArrived(_ raw: String, now: Date = Date(), timeZone: TimeZone = .current) -> Bool? {
        guard let day = calendarDay(raw, timeZone: timeZone),
              let dayStart = utcCalendar.date(from: day)
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let todayStart = utcCalendar.date(from: calendar.dateComponents([.year, .month, .day], from: now)) else {
            return nil
        }
        return dayStart <= todayStart
    }

    private static let abbreviatedDateCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2_000
        return cache
    }()

    private static func formattedDate(_ raw: String?, formatter: DateFormatter) -> String? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else {
            return nil
        }
        guard let day = calendarDay(cleaned), let date = utcCalendar.date(from: day) else { return cleaned }
        return formatter.string(from: date)
    }

    private static func literalDay(_ value: String) -> DateComponents? {
        guard matches(leadingDayPattern, value) else { return nil }
        let day = String(value.prefix(10))
        guard let date = dayParser.date(from: day), dayParser.string(from: date) == day else { return nil }
        return utcCalendar.dateComponents([.year, .month, .day], from: date)
    }

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// A bare day, or a day at midnight with or without an offset.
    private static let midnightPattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}(?:T00:00(?::00(?:\.0+)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?)?$"#
    )

    private static let leadingDayPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}(?!\d)"#)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let rfc3339Parser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    private static let rfc3339FractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // Days are built at midnight UTC, so they're shown in UTC to keep the day.
    private static let longDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let abbreviatedDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
