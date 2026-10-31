import Foundation

/// What Apple TV saves when it hands a trailer to the YouTube app, so a cold
/// launch soon afterwards can reopen the same detail page. The synthesised
/// coding is the stored format: earlier records must keep decoding.
struct TrailerReturnRecord: Codable, Equatable {
    let contentId: String
    let serverId: String
    let profileId: String
    let savedAt: Date
}

enum TrailerReturnPolicy {
    /// Half an hour: long enough to watch a trailer, short enough that an
    /// unrelated launch the next day opens Home as usual.
    static let maximumAge: TimeInterval = 1_800

    /// True when the record belongs to the active server and profile and was
    /// saved no more than the maximum age ago. A save time in the future
    /// never restores.
    static func shouldRestore(record: TrailerReturnRecord, now: Date, activeServerId: String?, activeProfileId: String?) -> Bool {
        guard let activeServerId, let activeProfileId,
              record.serverId == activeServerId, record.profileId == activeProfileId else { return false }
        let age = now.timeIntervalSince(record.savedAt)
        return age >= 0 && age <= maximumAge
    }
}
