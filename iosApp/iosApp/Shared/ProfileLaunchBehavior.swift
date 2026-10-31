import Foundation

/// When Vivid asks who's watching. The raw values are stored, so the three
/// choices Settings no longer offers still decode from older saved state.
enum ProfileLaunchBehavior: String, Codable, Sendable {
    case automatic
    case askEveryLaunch
    case afterOneHour
    case afterTwelveHours

    /// How long the app may sit in the background before the profile has to
    /// be chosen again. Nil when time away plays no part.
    var awayTimeout: TimeInterval? {
        switch self {
        case .automatic, .askEveryLaunch: nil
        case .afterOneHour: 3_600
        case .afterTwelveHours: 43_200
        }
    }
}
