import Foundation

/// One label and value row describing how the title is playing.
struct PlayerRouteStatusRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}
