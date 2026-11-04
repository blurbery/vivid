import Foundation

/// The player's time formats, shared so every overlay shows times the same way.
enum PlayerTimeFormatter {
    /// `h:mm:ss` from an hour up, otherwise `m:ss`. Negative and non-finite
    /// values show `0:00`, so a load without a duration yet shows nothing odd.
    static func formatHMS(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = wholeSeconds(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// A short runtime such as "1h 42m", "2h" or "42m", or an empty string
    /// for a zero or unknown duration so callers can leave it out.
    static func formatRuntime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = wholeSeconds(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 {
            return m > 0
                ? String(localized: "\(h)h \(m)m", comment: "Runtime in hours and minutes, abbreviated")
                : String(localized: "\(h)h", comment: "Runtime in hours, abbreviated")
        }
        return String(localized: "\(m)m", comment: "Runtime in minutes, abbreviated")
    }

    /// Truncated to whole seconds, capped below `Int.max` so a corrupt huge
    /// duration can't trap.
    private static func wholeSeconds(_ seconds: Double) -> Int {
        Int(min(seconds, 9.2233720368547748e18))
    }

    /// `m:ss`, for the sleep timer countdown.
    static func formatCountdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
