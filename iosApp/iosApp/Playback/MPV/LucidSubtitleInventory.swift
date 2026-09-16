#if (os(iOS) || os(tvOS))
import Foundation
import Libmpv
import Observation

/// File-derived inventory only. No catalogue subtitle rows enter this cache.
@Observable @MainActor
final class LucidSubtitleInventory {
    static let shared = LucidSubtitleInventory()
    private struct Key: Hashable { let scope: String; let content: String; let file: Int }
    private struct Entry { let tracks: [PlayerTrack]; let expires: Date }
    struct Choice { let trackID: Int64? }
    private var entries: [Key: Entry] = [:]
    private var choices: [Key: Choice] = [:]

    private func key(_ content: String, _ file: Int?) -> Key? {
        guard let scope = OpenSubtitlesStore.shared.scope, let file else { return nil }
        return Key(scope: scope, content: content, file: file)
    }
    func record(contentID: String, fileID: Int?, tracks: [PlayerTrack]) {
        guard let key = key(contentID, fileID) else { return }
        entries = entries.filter { $0.value.expires > Date() }
        if entries.count >= 8, entries[key] == nil { entries.removeAll() }
        entries[key] = Entry(tracks: tracks.filter { !$0.isExternal }, expires: Date().addingTimeInterval(300))
    }
    func choose(_ id: Int64?, context: OpenSubtitlePlaybackContext) {
        guard let key = key(context.contentID, context.fileID) else { return }
        choices = [key: Choice(trackID: id)]
        OpenSubtitlesStore.shared.clearStaged(context: context)
    }
    func clearChoice(context: OpenSubtitlePlaybackContext) {
        guard let key = key(context.contentID, context.fileID) else { return }
        choices.removeValue(forKey: key)
    }
    func takeChoice(contentID: String, fileID: Int?) -> Choice? {
        guard let key = key(contentID, fileID) else { return nil }
        return choices.removeValue(forKey: key)
    }
    func choice(context: OpenSubtitlePlaybackContext) -> Choice? {
        guard let key = key(context.contentID, context.fileID) else { return nil }
        return choices[key]
    }
    static func ordered(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        let settings = PlayerSettings.shared
        let language = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first : settings.preferredSubtitleLanguage
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

    func read(context: OpenSubtitlePlaybackContext) async throws -> [PlayerTrack] {
        guard let key = key(context.contentID, context.fileID) else { throw OpenSubtitlesError.context }
        if let entry = entries[key], entry.expires > Date() { return Self.ordered(entry.tracks) }
        let bridge = PlaybackSessionBridge()
        do {
            let prepared = try await bridge.startSession(contentId: context.contentID,
                preferredFileId: context.fileID, preferredSubtitleTrackIndex: -1,
                startFromBeginning: true, preferredQualityOverride: "original")
            try Task.checkCancellation()
            guard prepared.selectedVersion.fileId == context.fileID,
                  self.key(context.contentID, context.fileID) == key else { throw OpenSubtitlesError.context }
            let request: StreamRequest?
            if MediaServerProvider.active == .emby {
                request = await bridge.embyStreamRequest(sessionID: prepared.session.sessionId)
            } else {
                request = await StreamRequest.resolve(rawURL: prepared.session.streamUrl,
                    serverURL: VividAPI.shared.currentServerUrl(),
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:],
                    accessToken: VividAPI.shared.currentAccessToken(),
                    requiresHeaderAuthenticatedMedia: prepared.protocolV3?.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature) == true,
                    authorizedMediaOriginSessionId: prepared.protocolV3?.negotiatedAuthorizedMediaOrigins == true ? prepared.session.sessionId : nil)
            }
            guard let request else { throw OpenSubtitlesError.context }
            let tracks = try await LucidSubtitleProbe.read(request)
            await retire(bridge)
            try Task.checkCancellation()
            guard self.key(context.contentID, context.fileID) == key else { throw OpenSubtitlesError.context }
            record(contentID: context.contentID, fileID: context.fileID, tracks: tracks)
            return Self.ordered(tracks)
        } catch {
            await retire(bridge)
            throw error
        }
    }
    private func retire(_ bridge: PlaybackSessionBridge) async {
        // An uncancelled cleanup task closes only this probe's session and
        // never submits progress or marks the item watched.
        _ = await Task { await bridge.stopSession(position: 0, isPaused: true,
            eligible: false, finalProgressAlreadyReported: true) }.value
    }
}

private enum LucidSubtitleProbe {
    static func read(_ request: StreamRequest) async throws -> [PlayerTrack] {
        let task = Task.detached(priority: .utility) { () throws -> [TrackInfo] in
            guard let mpv = mpv_create() else { throw OpenSubtitlesError.file }
            defer { mpv_terminate_destroy(mpv) }
            for (name, value) in ["config":"no", "terminal":"no", "vo":"null", "ao":"null",
                "track-auto-selection":"no", "vid":"no", "aid":"no", "sid":"no", "pause":"yes", "idle":"yes", "keep-open":"yes",
                "cache":"no", "network-timeout":"10", "demuxer-max-bytes":"4194304"] {
                guard mpv_set_option_string(mpv, name, value) >= 0 else { throw OpenSubtitlesError.file }
            }
            VividMPVHeaders.apply(request.headers, to: mpv)
            guard mpv_initialize(mpv) >= 0 else { throw OpenSubtitlesError.file }
            let arguments = ["loadfile", request.url.absoluteString].map { strdup($0) }
            defer { arguments.forEach { free($0) } }
            var pointers: [UnsafePointer<CChar>?] = arguments.map { pointer in
                pointer.map { UnsafePointer<CChar>($0) }
            } + [nil]
            let status = pointers.withUnsafeMutableBufferPointer {
                mpv_command_async(mpv, 1, $0.baseAddress)
            }
            guard status >= 0 else { throw OpenSubtitlesError.file }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                try Task.checkCancellation()
                guard let event = mpv_wait_event(mpv, 0.05)?.pointee else { continue }
                if event.event_id == MPV_EVENT_FILE_LOADED {
                    var node = mpv_node()
                    guard mpv_get_property(mpv, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { throw OpenSubtitlesError.file }
                    defer { mpv_free_node_contents(&node) }
                    let raw = MpvPlayerCoreBase().convertNode(node) as? [[String: Any]] ?? []
                    return raw.filter { $0["type"] as? String == "sub" && $0["external"] as? Bool != true }
                        .map(VividMPVPlayer.trackInfo)
                }
                if event.event_id == MPV_EVENT_END_FILE { throw OpenSubtitlesError.file }
            }
            throw URLError(.timedOut)
        }
        let tracks = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        return await MainActor.run { tracks.map { LucidSubtitleInventory.playerTrack($0) } }
    }
}
#endif
