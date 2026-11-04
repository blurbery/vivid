// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if os(iOS) || os(tvOS)
import Foundation
import Libmpv
import Observation

/// The embedded subtitles a file has, read by opening it in Lucid, for the
/// detail page's subtitle menu, and the subtitle chosen there for the next
/// play. Only tracks read from the file enter this cache, never catalogue
/// subtitle rows.
@Observable @MainActor
final class LucidSubtitleInventory {
    static let shared = LucidSubtitleInventory()

    /// A choice made on the detail page. `label` names a server subtitle
    /// file, which the embedded reader never lists. `storedSubtitleID` names
    /// a subtitle Silo stores, which the player finds by that ID because its
    /// index can change.
    struct Choice {
        let trackID: Int64?
        var label: String? = nil
        var storedSubtitleID: Int? = nil
    }

    /// Entries and choices belong to one OpenSubtitles scope (server and
    /// profile), title and file.
    private struct Key: Hashable {
        let scope: String
        let content: String
        let file: Int
    }

    private struct Entry {
        let tracks: [PlayerTrack]
        let expires: Date
    }

    private static let entryLifetime: TimeInterval = 300
    private static let maximumEntries = 8

    private var entries: [Key: Entry] = [:]
    /// At most one choice is kept, for the title last chosen on.
    private var choices: [Key: Choice] = [:]

    private func key(_ content: String, _ file: Int?) -> Key? {
        guard let scope = OpenSubtitlesStore.shared.scope, let file else { return nil }
        return Key(scope: scope, content: content, file: file)
    }

    // MARK: Cache

    /// Keeps a file's embedded tracks for five minutes. A ninth file empties
    /// the cache first.
    func record(contentID: String, fileID: Int?, tracks: [PlayerTrack]) {
        guard let key = key(contentID, fileID) else { return }
        entries = entries.filter { $0.value.expires > Date() }
        if entries.count >= Self.maximumEntries, entries[key] == nil { entries.removeAll() }
        entries[key] = Entry(tracks: tracks.filter { !$0.isExternal },
                             expires: Date().addingTimeInterval(Self.entryLifetime))
    }

    /// The file's embedded tracks in menu order, from the cache or by
    /// opening the file through a session of its own.
    func read(context: OpenSubtitlePlaybackContext) async throws -> [PlayerTrack] {
        guard let key = key(context.contentID, context.fileID) else { throw OpenSubtitlesError.context }
        if let entry = entries[key], entry.expires > Date() { return Self.ordered(entry.tracks) }
        let bridge = PlaybackSessionBridge()
        do {
            let prepared = try await bridge.startSession(contentId: context.contentID,
                                                         preferredFileId: context.fileID,
                                                         preferredSubtitleTrackIndex: -1,
                                                         startFromBeginning: true,
                                                         preferredQualityOverride: "original")
            try Task.checkCancellation()
            guard prepared.selectedVersion.fileId == context.fileID,
                  self.key(context.contentID, context.fileID) == key else { throw OpenSubtitlesError.context }
            guard let request = await streamRequest(bridge: bridge, prepared: prepared) else {
                throw OpenSubtitlesError.context
            }
            let tracks = try await LucidSubtitleProbe.read(request)
            await retire(bridge)
            try Task.checkCancellation()
            // The profile or server may have changed while the file was read.
            guard self.key(context.contentID, context.fileID) == key else { throw OpenSubtitlesError.context }
            record(contentID: context.contentID, fileID: context.fileID, tracks: tracks)
            return Self.ordered(tracks)
        } catch {
            await retire(bridge)
            throw error
        }
    }

    /// The request each server's player would open, kept per provider.
    private func streamRequest(bridge: PlaybackSessionBridge,
                               prepared: PreparedPlayback) async -> StreamRequest? {
        switch MediaServerProvider.active {
        case .jellyfin:
            return await bridge.jellyfinStreamRequest(sessionID: prepared.session.sessionId)
        case .emby:
            return await bridge.embyStreamRequest(sessionID: prepared.session.sessionId)
        case .silo:
            let v3 = prepared.protocolV3
            return await StreamRequest.resolve(
                rawURL: prepared.session.streamUrl,
                serverURL: VividAPI.shared.currentServerUrl(),
                additionalHeaders: v3?.plan.stream.headers ?? [:],
                accessToken: VividAPI.shared.currentAccessToken(),
                requiresHeaderAuthenticatedMedia:
                    v3?.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature) == true,
                authorizedMediaOriginSessionId:
                    v3?.negotiatedAuthorizedMediaOrigins == true ? prepared.session.sessionId : nil,
                nativeApiMajor: v3?.plan.nativeApiMajor)
        }
    }

    private func retire(_ bridge: PlaybackSessionBridge) async {
        // An uncancelled cleanup task closes only this probe's session and
        // never submits progress or marks the item watched.
        _ = await Task {
            await bridge.stopSession(position: 0, isPaused: true, eligible: false,
                                     finalProgressAlreadyReported: true)
        }.value
    }

    // MARK: Choices

    /// Replaces any earlier choice, and any staged or remembered
    /// OpenSubtitles file for this title.
    func choose(_ id: Int64?, label: String? = nil, storedSubtitleID: Int? = nil,
                context: OpenSubtitlePlaybackContext) {
        guard let key = key(context.contentID, context.fileID) else { return }
        choices = [key: Choice(trackID: id, label: label, storedSubtitleID: storedSubtitleID)]
        OpenSubtitlesStore.shared.clearStaged(context: context)
        OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: context.fileID)
    }

    func clearChoice(context: OpenSubtitlePlaybackContext) {
        // Auto, or a new detail-page download, replaces a remembered file.
        OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: context.fileID)
        guard let key = key(context.contentID, context.fileID) else { return }
        choices.removeValue(forKey: key)
    }

    /// The choice for the play about to start, which uses it up.
    func takeChoice(contentID: String, fileID: Int?) -> Choice? {
        guard let key = key(contentID, fileID) else { return nil }
        return choices.removeValue(forKey: key)
    }

    func choice(context: OpenSubtitlePlaybackContext) -> Choice? {
        guard let key = key(context.contentID, context.fileID) else { return nil }
        return choices[key]
    }

    /// The menu's label: a staged download, then the choice, then `fallback`.
    func selectionLabel(context: OpenSubtitlePlaybackContext?, fallback: String) -> String {
        guard let context, let key = key(context.contentID, context.fileID) else { return fallback }
        if let staged = OpenSubtitlesStore.shared.stagedLabel(context: context) { return staged }
        guard let choice = choices[key] else { return fallback }
        guard let id = choice.trackID else { return String(localized: "Off") }
        return entries[key]?.tracks.first { $0.trackId == id }?.languageFirstPrimaryLabel
            ?? choice.label ?? String(localized: "On")
    }

    // MARK: Tracks

    /// Menu order, led by the subtitle language Settings prefers.
    static func ordered(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        let settings = PlayerSettings.shared
        let language = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : settings.preferredSubtitleLanguage
        return SubtitleDisplayOrder.order(tracks, preferredLanguage: language) {
            .init(language: $0.lang, codec: $0.codec, isForced: $0.isForced,
                  isHearingImpaired: $0.isHearingImpaired, isDefault: $0.isDefault)
        }
    }

    static func playerTrack(_ track: TrackInfo, selectedID: Int? = nil) -> PlayerTrack {
        PlayerTrack(trackId: Int64(track.id), kind: .sub, title: track.name, lang: track.language,
                    codec: track.codec, audioChannelCount: nil, bitrate: nil, isDefault: track.isDefault,
                    isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                    isExternal: false, isSelected: track.id == selectedID,
                    ffIndex: track.sourceStreamIndex ?? track.id, srcId: nil)
    }
}

/// Opens a file in a headless mpv context, without audio, video or a cache,
/// and lists its embedded subtitle tracks.
private enum LucidSubtitleProbe {
    private static let options: [(name: String, value: String)] = [
        ("config", "no"), ("load-scripts", "no"), ("terminal", "no"), ("vo", "null"), ("ao", "null"),
        ("track-auto-selection", "no"), ("vid", "no"), ("aid", "no"), ("sid", "no"), ("pause", "yes"),
        ("idle", "yes"), ("keep-open", "yes"), ("cache", "no"), ("network-timeout", "10"),
        ("demuxer-max-bytes", "4194304"),
    ]

    /// Gives up after 20 seconds.
    static func read(_ request: StreamRequest) async throws -> [PlayerTrack] {
        let task = Task.detached(priority: .utility) { () throws -> [TrackInfo] in
            try readTracks(request)
        }
        let tracks = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        return await MainActor.run { tracks.map { LucidSubtitleInventory.playerTrack($0) } }
    }

    private static func readTracks(_ request: StreamRequest) throws -> [TrackInfo] {
        guard let mpv = mpv_create() else { throw OpenSubtitlesError.file }
        defer { mpv_terminate_destroy(mpv) }
        for option in options {
            guard mpv_set_option_string(mpv, option.name, option.value) >= 0 else { throw OpenSubtitlesError.file }
        }
        guard LucidTLS.apply(to: mpv) >= 0 else { throw OpenSubtitlesError.file }
        VividMPVHeaders.apply(request.headers, to: mpv)
        guard mpv_initialize(mpv) >= 0 else { throw OpenSubtitlesError.file }
        let status = "loadfile".withCString { command in
            request.url.absoluteString.withCString { url in
                var arguments: [UnsafePointer<CChar>?] = [command, url, nil]
                return arguments.withUnsafeMutableBufferPointer { mpv_command_async(mpv, 1, $0.baseAddress) }
            }
        }
        guard status >= 0 else { throw OpenSubtitlesError.file }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let event = mpv_wait_event(mpv, 0.05)?.pointee else { continue }
            if event.event_id == MPV_EVENT_FILE_LOADED {
                var node = mpv_node()
                guard mpv_get_property(mpv, "track-list", MPV_FORMAT_NODE, &node) >= 0 else {
                    throw OpenSubtitlesError.file
                }
                defer { mpv_free_node_contents(&node) }
                let tracks = VividPlayerCoreBase().convertNode(node) as? [[String: Any]] ?? []
                return tracks.filter { $0["type"] as? String == "sub" && $0["external"] as? Bool != true }
                    .map(VividMPVPlayer.trackInfo)
            }
            if event.event_id == MPV_EVENT_END_FILE { throw OpenSubtitlesError.file }
        }
        throw URLError(.timedOut)
    }
}
#endif
