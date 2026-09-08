//
//  SubtitleTrackIdentity.swift
//  Vivid (iOS + tvOS)
//
//  Subtitle slots and server protocol track identities.
//

import Foundation

/// Primary vs secondary subtitle slot. Matches the user-facing notion of
/// a main caption line + an optional second line (e.g. dual-language
/// learning setups).
enum SubtitleSlot: Int, CaseIterable, Hashable {
    case primary = 0
    case secondary = 1
}

/// VividKit embedded tracks use their media-stream ids directly.
/// Server protocol ordinals occupy a separate, bounded id range.
enum SubtitleTrackIdSpace {
    static let sidecarBase: Int64 = 0x4000_0000
    private static let sidecarLimit: Int64 = 0x6000_0000

    static func makeSidecarTrackId(urlIndex: Int) -> Int64 {
        Self.sidecarBase | Int64(urlIndex)
    }

    static func isSidecar(_ trackId: Int64) -> Bool {
        trackId >= Self.sidecarBase && trackId < Self.sidecarLimit
    }

    static func sidecarIndex(from trackId: Int64) -> Int {
        Int(trackId & (Self.sidecarBase - 1))
    }

}
