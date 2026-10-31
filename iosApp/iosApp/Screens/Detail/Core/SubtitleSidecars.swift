import Foundation

/// A file's catalogue subtitles as player tracks, in the order and with the
/// identities the playback plan's combined index gives them: subtitle files
/// beside the media first, then the embedded streams.
enum SubtitleTrackCandidates {
    static func indexedPlayerTracks(from tracks: [SubtitleTrack]) -> [(ordinal: Int, track: PlayerTrack)] {
        let ordered = tracks.filter { $0.external == true } + tracks.filter { $0.external != true }
        var externalCount = 0
        var result: [(ordinal: Int, track: PlayerTrack)] = []
        result.reserveCapacity(ordered.count)
        for (ordinal, track) in ordered.enumerated() {
            let isExternal = track.external == true
            let trackId: Int64
            let sourceId: Int?
            if isExternal {
                trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: externalCount)
                sourceId = externalCount
                externalCount += 1
            } else {
                trackId = Int64(track.selectionIndex ?? 0)
                sourceId = nil
            }
            let playerTrack = PlayerTrack(
                trackId: trackId, kind: .sub, title: track.title ?? track.embeddedTitle,
                lang: track.language, codec: track.codec, audioChannelCount: nil, bitrate: nil,
                isDefault: track.isDefault == true, isForced: track.forced == true,
                isHearingImpaired: track.hearingImpaired == true, isExternal: isExternal,
                isSelected: false, ffIndex: isExternal ? nil : track.selectionIndex, srcId: sourceId)
            result.append((ordinal: ordinal, track: playerTrack))
        }
        return result
    }

    static func playerTracks(from tracks: [SubtitleTrack]) -> [PlayerTrack] {
        indexedPlayerTracks(from: tracks).map(\.track)
    }
}

/// Server subtitle files the player can fetch and mount itself, and the
/// subtitles Silo stores for a file, as rows for the player and the detail
/// subtitle menus.
enum ServerSubtitleSidecars {
    /// Text formats the player renders from a fetched file.
    private static let textCodecs: Set<String> = ["srt", "ass", "ssa", "vtt", "subrip", "webvtt"]

    static func isMountable(codec: String?) -> Bool {
        guard let codec else { return false }
        return textCodecs.contains(codec.lowercased())
    }

    /// The file extension for a fetched subtitle.
    static func format(_ codec: String) -> String {
        let lowered = codec.lowercased()
        switch lowered {
        case "subrip": return "srt"
        case "webvtt": return "vtt"
        default: return lowered
        }
    }

    /// A Silo plan item the player offers as a row fetched only when chosen:
    /// a subtitle file beside the media or a stored one, sent as a text
    /// sidecar.
    static func isSiloLocalSidecar(_ item: PlaybackV3SubtitleInventoryItem) -> Bool {
        (item.source == "external" || item.source == "downloaded")
            && item.delivery == "sidecar"
            && isMountable(codec: item.codec)
    }

    /// The stored subtitle a player sidecar URL serves, if it names one.
    static func storedSubtitleID(in url: URL) -> Int? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let value = items.first(where: { $0.name == "downloaded_subtitle_id" })?.value else { return nil }
        return Int(value)
    }

    /// The player's sidecar for a stored subtitle (the lowest track id when
    /// more than one carries it).
    static func sidecarTrackID(storedSubtitleID: Int, in sidecars: [Int64: ExternalSubtitleTrack]) -> Int64? {
        sidecars
            .filter { Self.storedSubtitleID(in: $0.value.url) == storedSubtitleID }
            .keys
            .min()
    }

    /// The server subtitle files a detail page's subtitle menu offers. Silo
    /// rows are keyed by position among the file's subtitle files and are
    /// followed by its stored subtitles; Emby and Jellyfin rows are keyed by
    /// the server's stream index.
    @MainActor static func detailRows(_ tracks: [SubtitleTrack]?, fileID: Int? = nil) -> [PlayerTrack] {
        let catalog = tracks ?? []
        switch MediaServerProvider.active {
        case .silo:
            var rows: [PlayerTrack] = []
            for (position, track) in catalog.filter({ $0.external == true }).enumerated()
            where isMountable(codec: track.codec) {
                rows.append(fileRow(track, key: position))
            }
            return rows + storedRows(SiloStoredSubtitles.shared.subtitles(fileID: fileID), catalog: catalog)
        case .emby, .jellyfin:
            return catalog.compactMap { track in
                guard track.external == true, let index = track.index, index >= 0,
                      isMountable(codec: track.codec) else { return nil }
                return fileRow(track, key: index)
            }
        }
    }

    /// Whether a Silo sidecar ordinal still points at the same subtitle file
    /// in the playback plan as in the catalogue. Without a plan there is
    /// nothing to disagree with.
    static func siloOrdinalAgrees(_ trackID: Int64, plan: PlaybackV3Plan?, catalog: [SubtitleTrack]?) -> Bool {
        guard let plan else { return true }
        let index = SubtitleTrackIdSpace.sidecarIndex(from: trackID)
        let planFiles = plan.subtitle.inventory
            .filter { $0.source == "external" }
            .sorted { $0.combinedIndex < $1.combinedIndex }
        let catalogueFiles = (catalog ?? []).filter { $0.external == true }
        guard planFiles.count == catalogueFiles.count, planFiles.indices.contains(index),
              planFiles[index].combinedIndex == index else { return false }
        let item = planFiles[index]
        let track = catalogueFiles[index]
        guard item.language?.lowercased() == track.language?.lowercased(),
              item.codec.map(format) == track.codec.map(format),
              let label = item.label else { return false }
        return label == track.title || label == track.embeddedTitle || label == track.externalPath
    }

    /// Silo's stored subtitles as rows keyed by the combined index Silo gives
    /// them, after every catalogue track. Formats the player can't mount get
    /// no row but keep their place.
    static func storedRows(_ stored: [SiloStoredSubtitle], catalog: [SubtitleTrack]?) -> [PlayerTrack] {
        let base = catalog?.count ?? 0
        return stored.enumerated().compactMap { offset, subtitle in
            guard let codec = subtitle.format, isMountable(codec: codec) else { return nil }
            let key = base + offset
            return PlayerTrack(
                trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: key), kind: .sub,
                title: subtitle.planLabel, lang: subtitle.language, codec: format(codec),
                audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: false,
                isHearingImpaired: subtitle.hearingImpaired, isExternal: true, isSelected: false,
                ffIndex: nil, srcId: key)
        }
    }

    /// The stored subtitle behind a detail menu row, on Silo only.
    @MainActor static func detailStoredSubtitleID(_ trackID: Int64, catalog: [SubtitleTrack]?, fileID: Int?) -> Int? {
        guard MediaServerProvider.active == .silo else { return nil }
        return storedSubtitleID(forDetailRow: trackID, stored: SiloStoredSubtitles.shared.subtitles(fileID: fileID), catalog: catalog)
    }

    static func storedSubtitleID(forDetailRow trackID: Int64, stored: [SiloStoredSubtitle], catalog: [SubtitleTrack]?) -> Int? {
        guard SubtitleTrackIdSpace.isSidecar(trackID) else { return nil }
        let offset = SubtitleTrackIdSpace.sidecarIndex(from: trackID) - (catalog?.count ?? 0)
        guard stored.indices.contains(offset) else { return nil }
        return stored[offset].id
    }

    private static func fileRow(_ track: SubtitleTrack, key: Int) -> PlayerTrack {
        PlayerTrack(
            trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: key), kind: .sub,
            title: track.title ?? track.embeddedTitle, lang: track.language,
            codec: track.codec.map(format), audioChannelCount: nil, bitrate: nil,
            isDefault: track.isDefault == true, isForced: track.forced == true,
            isHearingImpaired: track.hearingImpaired == true, isExternal: true, isSelected: false,
            ffIndex: nil, srcId: key)
    }
}
