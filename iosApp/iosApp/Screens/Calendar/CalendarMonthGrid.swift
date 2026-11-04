import Foundation

/// The month grid that the iPhone, iPad and Apple TV Calendar month sheets
/// draw, in the device's own calendar and first weekday.
enum CalendarMonthGrid {
    /// The month a page's window ends in, `windowDays` after today.
    static func lastMonth(windowDays: Int, today: Date, calendar: Calendar = .current) -> Date {
        let firstMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let end = calendar.date(byAdding: .day, value: windowDays, to: today) ?? today
        return calendar.dateInterval(of: .month, for: end)?.start ?? firstMonth
    }

    /// The month's days, after blanks for the days before the 1st.
    static func cells(for month: Date, calendar: Calendar = .current) -> [Date?] {
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading)
            + days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    /// Weekday symbols from the calendar, starting on its first weekday.
    static func weekdaySymbols(_ symbols: [String], calendar: Calendar = .current) -> [String] {
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

extension CalendarStore {
    /// Upcoming, one entry for each day with something on it, in order.
    var upcomingByDay: [(day: Date, episodes: [UpcomingEpisode])] {
        Dictionary(grouping: upcoming, by: \.day)
            .map { ($0.key, $0.value) }
            .sorted { $0.day < $1.day }
    }
}

extension UpcomingEpisode {
    /// The episode code and name, such as "S1 · E2 · Pilot".
    var episodeLine: String {
        var parts: [String] = []
        if let season { parts.append(String(localized: "S\(String(season))", comment: "Season number in an episode code, e.g. S1")) }
        if let number { parts.append(String(localized: "E\(String(number))", comment: "Episode number in an episode code, e.g. E2")) }
        if let name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}
