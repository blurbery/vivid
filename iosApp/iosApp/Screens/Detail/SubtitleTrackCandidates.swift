import Foundation

/// Maps detail payload subtitle metadata into the exact candidate shape the
/// player's auto resolver consumes.
///
/// Candidates are ordered external-first to match the Protocol V3 combined
/// ordinal space (externals, then embedded, then downloaded). The watch detail
/// lists embedded tracks before externals, and the resolver is first-match
/// within a track class, so resolving in catalog order picks a different
/// track than the post-load resolver does over the plan inventory. That
/// disagreement forced a `subtitle_track_changed` replan, and a full engine
/// reload, on every episode start.
enum SubtitleTrackCandidates {
    /// `ordinal` is the position in the returned combined order, not the
    /// catalog offset the track came from.
    static func indexedPlayerTracks(
        from tracks: [SubtitleTrack]
    ) -> [(ordinal: Int, track: PlayerTrack)] {
        var externalOrdinal = 0
        let combinedOrder = tracks.filter { $0.external == true }
            + tracks.filter { $0.external != true }
        return combinedOrder.enumerated().compactMap { ordinal, track in
            let isExternal = track.external == true
            let trackId: Int64
            let sourceIndex: Int?
            if isExternal {
                sourceIndex = externalOrdinal
                trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: externalOrdinal)
                externalOrdinal += 1
            } else {
                // Embedded tracks always resolve: `selectionIndex` reads a
                // missing wire index (`index,omitempty`) as FFmpeg stream 0.
                let index = track.selectionIndex ?? 0
                sourceIndex = nil
                trackId = Int64(index)
            }

            return (
                ordinal,
                PlayerTrack(
                    trackId: trackId,
                    kind: .sub,
                    title: track.title ?? track.embeddedTitle,
                    lang: track.language,
                    codec: track.codec,
                    audioChannelCount: nil,
                    bitrate: nil,
                    isDefault: track.isDefault ?? false,
                    isForced: track.forced ?? false,
                    isHearingImpaired: track.hearingImpaired ?? false,
                    isExternal: isExternal,
                    isSelected: false,
                    ffIndex: isExternal ? nil : track.selectionIndex,
                    srcId: sourceIndex
                )
            )
        }
    }

    static func playerTracks(from tracks: [SubtitleTrack]) -> [PlayerTrack] {
        indexedPlayerTracks(from: tracks).map(\.track)
    }
}

/// Text subtitle files a server keeps beside the media. Emby and Jellyfin
/// rows are keyed by the server stream index, which the player mounts. Silo
/// rows are keyed by position among the file's external files, which is the
/// playback plan's combined index, and the player fetches one only when chosen.
enum ServerSubtitleSidecars {
    static let mountableCodecs: Set<String> = ["srt", "ass", "ssa", "vtt", "subrip", "webvtt"]
    static let siloTextCodecs: Set<String> = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa"]

    static func isMountable(codec: String?) -> Bool {
        codec.map { mountableCodecs.contains($0.lowercased()) } ?? false
    }

    static func format(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": "srt"
        case "webvtt": "vtt"
        case let other: other
        }
    }

    @MainActor
    static func detailRows(_ tracks: [SubtitleTrack]?) -> [PlayerTrack] {
        let tracks = tracks ?? []
        if MediaServerProvider.active == .silo {
            return tracks.filter { $0.external == true }.enumerated().compactMap { ordinal, track in
                guard let codec = track.codec, siloTextCodecs.contains(codec.lowercased()) else { return nil }
                return row(track, index: ordinal, codec: format(codec))
            }
        }
        return tracks.compactMap { track in
            guard track.external == true, let index = track.index, index >= 0,
                  let codec = track.codec, isMountable(codec: codec) else { return nil }
            return row(track, index: index, codec: format(codec))
        }
    }

    /// A Silo detail row names an external file by position, so it applies
    /// only while the catalogue and the plan list the same external files:
    /// externals first in the combined index, the same count, and the same
    /// language, format and name at that position. Emby and Jellyfin rows use
    /// the server index and always agree.
    static func siloOrdinalAgrees(_ trackID: Int64, plan: PlaybackV3Plan?, catalog: [SubtitleTrack]?) -> Bool {
        guard let plan else { return true }
        let ordinal = SubtitleTrackIdSpace.sidecarIndex(from: trackID)
        let inventory = plan.subtitle.inventory.filter { $0.source == "external" }.sorted { $0.combinedIndex < $1.combinedIndex }
        let externals = (catalog ?? []).filter { $0.external == true }
        guard inventory.count == externals.count, inventory.indices.contains(ordinal),
              inventory[ordinal].combinedIndex == ordinal else { return false }
        let item = inventory[ordinal], row = externals[ordinal]
        guard item.language?.lowercased() == row.language?.lowercased(),
              item.codec.map(format) == row.codec.map(format),
              let label = item.label else { return false }
        // Silo labels an external file by its title, embedded title or file name.
        return [row.title, row.embeddedTitle, row.externalPath].contains(label)
    }

    private static func row(_ track: SubtitleTrack, index: Int, codec: String) -> PlayerTrack {
        PlayerTrack(
            trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: index),
            kind: .sub,
            title: track.title ?? track.embeddedTitle,
            lang: track.language,
            codec: codec,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: track.isDefault == true,
            isForced: track.forced == true,
            isHearingImpaired: track.hearingImpaired == true,
            isExternal: true,
            isSelected: false,
            ffIndex: nil,
            srcId: index
        )
    }
}
