import Foundation

/// The primary subtitle line and an optional second one (for dual-language
/// viewing, for example).
enum SubtitleSlot: Int, CaseIterable, Hashable {
    case primary = 0
    case secondary = 1
}

/// Subtitle track ids. Lucid's embedded tracks use their stream ids as they
/// are; sidecar tracks (server subtitle files and other external tracks) use
/// a separate bounded range keyed by their sidecar index.
enum SubtitleTrackIdSpace {
    static let sidecarBase: Int64 = 0x4000_0000
    private static let sidecarLimit: Int64 = 0x6000_0000

    static func makeSidecarTrackId(urlIndex: Int) -> Int64 {
        sidecarBase | Int64(urlIndex)
    }

    static func isSidecar(_ trackId: Int64) -> Bool {
        trackId >= sidecarBase && trackId < sidecarLimit
    }

    static func sidecarIndex(from trackId: Int64) -> Int {
        Int(trackId & (sidecarBase - 1))
    }
}
