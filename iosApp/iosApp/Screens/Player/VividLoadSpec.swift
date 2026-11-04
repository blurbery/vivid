import Foundation

/// The one rule for which audio track a load starts with. The session bridge,
/// the detail pages, the Continue Watching badges and offline playback all
/// use it, and none of them reads a server's remembered audio choice.
enum VividInitialAudioPreference {
    /// Codecs every Apple device plays natively, besides PCM.
    private static let compatibleCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    /// The audio ordinal to start with. A manual pick wins. Otherwise the
    /// tracks in the preferred language (or English when there are none and
    /// the preference isn't Original Language), preferring the file's default
    /// among them, then the file's default, then the first track. Within that
    /// track's language a compatible, non-commentary track is preferred.
    static func selectedOrdinal(manual: Int?, tracks: [AudioTrack], preferredLanguage: String) -> Int? {
        if let manual { return manual }
        guard !tracks.isEmpty else { return nil }

        let language = preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        func indices(matching target: String) -> [Int] {
            tracks.indices.filter { index in
                tracks[index].language.map { SubtitleAutoResolver.languagesMatch($0, target) } == true
            }
        }
        var matching = language.isEmpty ? [] : indices(matching: language)
        if matching.isEmpty && !language.isEmpty && language != PlaybackPrefSentinel.originalLanguage {
            matching = indices(matching: "en")
        }

        let chosen = matching.first(where: { tracks[$0].isDefault == true }) ?? matching.first
            ?? tracks.firstIndex(where: { $0.isDefault == true }) ?? 0
        let chosenLanguage = trimmedLanguage(tracks[chosen])
        let candidates = !matching.isEmpty ? matching : tracks.indices.filter { index in
            let candidate = trimmedLanguage(tracks[index])
            return chosenLanguage.isEmpty ? candidate.isEmpty
                : SubtitleAutoResolver.languagesMatch(candidate, chosenLanguage)
        }
        let compatible = candidates.filter { isCompatible(tracks[$0]) }
        if compatible.contains(chosen) { return chosen }
        return compatible.first(where: { tracks[$0].isDefault == true }) ?? compatible.first ?? chosen
    }

    /// The language automatic audio aims for: one picked earlier in this
    /// viewing, when the file has a track in it, otherwise Settings >
    /// Playback > Audio Language. So a viewer who switches an episode to
    /// Japanese gets Japanese in the next one, and a next episode without
    /// Japanese falls back to Settings rather than straight to English.
    static func preferredLanguage(viewing: String?, settings: String, tracks: [AudioTrack]) -> String {
        guard let viewing = viewing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !viewing.isEmpty,
              tracks.contains(where: { track in
                  track.language.map { SubtitleAutoResolver.languagesMatch($0, viewing) } == true
              }) else {
            return settings
        }
        return viewing
    }

    /// The audio languages to hand the engine: the selected track's, or with
    /// no selection the fallback language followed by English (none for
    /// Original Language).
    static func languages(selectedOrdinal: Int?, tracks: [AudioTrack], fallbackLanguage: String) -> [String] {
        if let selectedOrdinal {
            guard tracks.indices.contains(selectedOrdinal) else { return [] }
            let selectedLanguage = trimmedLanguage(tracks[selectedOrdinal])
            return selectedLanguage.isEmpty ? [] : [selectedLanguage]
        }
        let fallback = fallbackLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback != PlaybackPrefSentinel.originalLanguage else { return [] }
        return SubtitleAutoResolver.languagesMatch(fallback, "en") ? [fallback] : [fallback, "en"]
    }

    private static func trimmedLanguage(_ track: AudioTrack) -> String {
        track.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isCompatible(_ track: AudioTrack) -> Bool {
        let codec = track.codec?.lowercased() ?? ""
        let title = ((track.title ?? "") + " " + (track.embeddedTitle ?? "")).lowercased()
        return (compatibleCodecs.contains(codec) || codec.hasPrefix("pcm")) && !title.contains("commentary")
    }
}

/// Decides whether a committed load failed because the bearer frozen into its
/// media request expired, and whether rebuilding it would install a different
/// credential.
///
/// Typed and token-agnostic: AVFoundation localises its messages, while the
/// error domain and code and the source-refusal status are stable. Comparing
/// the whole header value allows one reload per credential, so a revoked
/// current token falls through to the normal Protocol V3 route ladder instead
/// of looping on the same URL.
enum VividAuthenticationRecoveryPolicy {
    /// The failure to report when renewing playback ends in `error`.
    @MainActor
    static func finalFailure(_ error: Error) -> PlaybackErrorInfo {
        if let load = error as? VividPlaybackController.LoadFailure { return load.failure }
        if let typed = error as? PlaybackErrorInfo { return typed }
        if let http = error as? HTTPError {
            switch http {
            case .http(let status, _):
                return PlaybackErrorInfo(kind: status == 429 ? .sourceRateLimited : .sourceRefused,
                    message: "The server returned HTTP \(status) while renewing playback.",
                    underlyingDomain: NSURLErrorDomain, underlyingCode: status)
            case .network(let underlying):
                let native = underlying as NSError
                return PlaybackErrorInfo(kind: .vodSourceFailed,
                    message: "The server could not be reached while renewing playback.",
                    underlyingDomain: native.domain, underlyingCode: native.code)
            default:
                break
            }
        }
        let native = error as NSError
        return PlaybackErrorInfo(kind: .softwarePipelineFailed,
            message: error.localizedDescription,
            underlyingDomain: native.domain, underlyingCode: native.code)
    }

    static func isExpiredBearerFailure(_ failure: PlaybackErrorInfo) -> Bool {
        PlaybackErrorInfo.isHTTPAuthenticationFailure(failure)
    }

    // scripts/tests/playback-auth-refresh-tests.py copies the next three
    // functions out by name, so they must use nothing else from this file.

    /// True when the refreshed headers carry an Authorization value that
    /// differs from the failed one.
    static func shouldReload(
        failedHeaders: [String: String],
        refreshedHeaders: [String: String]
    ) -> Bool {
        guard let refreshed = authorizationHeader(in: refreshedHeaders) else { return false }
        return authorizationHeader(in: failedHeaders) != refreshed
    }

    /// After a successful progress report, true when the session's current
    /// headers carry a new Authorization value for the playing source.
    static func shouldUpdateHeadersAfterProgress(
        _ result: PlaybackProgressReportResult,
        activeHeaders: [String: String],
        currentHeaders: [String: String]
    ) -> Bool {
        result == .success && shouldReload(failedHeaders: activeHeaders, refreshedHeaders: currentHeaders)
    }

    private static func authorizationHeader(in headers: [String: String]) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare("Authorization") == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One authentication recovery attempt per credential generation, which a
/// successful recovery gives back.
struct VividAuthenticationRecoveryBudget {
    private(set) var generation: UInt64?
    private(set) var attempted = false

    mutating func begin(generation: UInt64) -> Bool {
        if self.generation != generation {
            self.generation = generation
            attempted = false
        }
        guard !attempted else { return false }
        attempted = true
        return true
    }

    mutating func recovered(generation: UInt64) {
        guard self.generation == generation else { return }
        attempted = false
    }
}

/// Bounds same-route reopening after a stream ends before its real end. The
/// engine reconnects with the bearer it opened with, so once that access token
/// expires a dropped connection can't be resumed and reads as an early end. A
/// long film can outlive several tokens, so recovery is allowed again, but only
/// after real playback since the previous attempt. A source that is really
/// truncated ends again straight away and falls through to server recovery.
struct VividPrematureEndRecoveryGate {
    static let requiredPlaybackSeconds: Double = 30
    private var attempted = false
    private(set) var playedSinceAttempt: Double = 0
    private var previous: (position: Double, uptime: Double)?

    /// Counts playback since the last attempt from consecutive samples no
    /// more than three seconds apart whose position moved forward at a
    /// plausible rate.
    mutating func observe(position: Double, uptime: Double, playing: Bool, rate: Double) {
        guard attempted else { return }
        guard playing, position.isFinite, uptime.isFinite, rate.isFinite, rate > 0 else {
            previous = nil
            return
        }
        defer { previous = (position, uptime) }
        guard let previous else { return }
        let elapsed = uptime - previous.uptime
        let advanced = position - previous.position
        guard elapsed > 0, elapsed <= 3, advanced > 0, advanced <= elapsed * rate + 0.5 else { return }
        playedSinceAttempt += min(elapsed, advanced / rate)
    }

    mutating func begin() -> Bool {
        guard !attempted || playedSinceAttempt >= Self.requiredPlaybackSeconds else { return false }
        attempted = true
        playedSinceAttempt = 0
        previous = nil
        return true
    }
}

/// Whether a reloaded stream has settled after authentication recovery: paused
/// and ready when playback isn't wanted, otherwise half a second of steady
/// forward play.
struct VividAuthenticationRecoveryReadiness {
    private var previousTime: Double?
    private var advancingSeconds: Double = 0

    mutating func observe(time: Double, ready: Bool, wantsPlayback: Bool,
                          playing: Bool, paused: Bool, seeking: Bool) -> Bool {
        defer { previousTime = time.isFinite ? time : nil }
        guard ready, !seeking, time.isFinite else {
            advancingSeconds = 0
            return false
        }
        if !wantsPlayback { return paused }
        guard playing, let previousTime, time > previousTime, time - previousTime < 1 else {
            advancingSeconds = 0
            return false
        }
        advancingSeconds += time - previousTime
        return advancingSeconds >= 0.5
    }
}

/// The fixed inputs for one engine load.
///
/// The initialisers are main-actor isolated because they sample the display
/// when building `LoadOptions`: the display-criteria handshake runs inside
/// `load`, so `panelIsInHDRMode` and `matchContentEnabled` must describe the
/// panel at that point. An explicit `panelIsInHDRMode` overrides the sample;
/// nil means sample now.
struct VividLoadSpec {
    enum ValidationError: Error, Equatable {
        case invalidStreamURL(String)
        case unsupportedDelivery(String)
        case invalidAudioTrackIndex(Int)
        case invalidSubtitleArtifactURL(String)
        case unsupportedSubtitleTimingOrigin(origin: Double, timelineOffset: Double)
    }

    let planID: String
    let sessionID: String
    let delivery: String
    let sourceURL: URL
    let timeline: PlaybackTimelineMapper
    /// The player-axis start handed to the engine. Usually the plan's start;
    /// a same-plan credential reload resumes at the current source position
    /// mapped through the same timeline.
    let vividStartPosition: Double
    private(set) var options: LoadOptions
    let audioSourceStreamIndex: Int32?

    mutating func updateHTTPHeaders(_ headers: [String: String]) {
        options.httpHeaders = headers
    }

    /// A downloaded file.
    @MainActor
    init(
        offlineURL: URL,
        startPosition: Double,
        audioOnly: Bool,
        audioSourceStreamIndex: Int32? = nil,
        audioTrackOrdinal: Int? = nil,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        guard offlineURL.isFileURL else {
            throw ValidationError.invalidStreamURL(offlineURL.absoluteString)
        }
        planID = "offline"
        sessionID = "offline"
        delivery = PlaybackProtocolV3.PlanDelivery.originalHTTP
        sourceURL = offlineURL
        timeline = PlaybackTimelineMapper(directStartSeconds: startPosition)
        vividStartPosition = timeline.vividStartPosition
        self.audioSourceStreamIndex = audioSourceStreamIndex
        options = LoadOptions(
            panelIsInHDRMode: panelIsInHDRMode ?? VividDisplayContext.panelIsInHDRMode,
            audioOnly: audioOnly,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: [],
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            audioTrackOrdinal: audioTrackOrdinal
        )
    }

    /// A direct URL outside Protocol V3 (Emby and Jellyfin streams).
    @MainActor
    init(
        directURL: URL,
        headers: [String: String],
        startPosition: Double,
        audioOnly: Bool,
        nativeAudioStreamIndex: Int32? = nil,
        nativeHLS: Bool = false,
        matchContentEnabled: Bool = true,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        guard ["http", "https", "file"].contains(directURL.scheme?.lowercased() ?? "") else {
            throw ValidationError.invalidStreamURL(directURL.absoluteString)
        }
        planID = "legacy-direct"
        sessionID = "legacy-direct"
        delivery = PlaybackProtocolV3.PlanDelivery.originalHTTP
        sourceURL = directURL
        timeline = PlaybackTimelineMapper(directStartSeconds: startPosition)
        vividStartPosition = timeline.vividStartPosition
        audioSourceStreamIndex = nativeAudioStreamIndex
        options = LoadOptions(
            httpHeaders: headers,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode ?? VividDisplayContext.panelIsInHDRMode,
            audioOnly: audioOnly,
            nativeRemoteHLS: nativeHLS,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: [],
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false
        )
    }

    /// A validated Silo Protocol V3 plan.
    ///
    /// `requestHeaders` are the plan's headers with the current bearer added
    /// by `StreamRequest`, and apply to the media and same-origin subtitle
    /// artefacts; without them the plan's own headers are used.
    @MainActor
    init(
        validating plan: PlaybackV3Plan,
        sessionID: String,
        matchContentEnabled: Bool,
        sourceURLOverride: URL? = nil,
        requestHeaders: [String: String]? = nil,
        resolveURL: ((String) -> URL?)? = nil,
        apiOriginURL: URL? = nil,
        audioSourceStreamIndex: Int32? = nil,
        preferredAudioLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        resumeSourcePosition: Double? = nil,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        try ApplePlaybackV3PlanAdapter.validate(plan)
        let planURL: URL?
        if let resolveURL {
            planURL = resolveURL(plan.stream.url)
        } else {
            planURL = URL(string: plan.stream.url)
        }
        guard let sourceURL = sourceURLOverride ?? planURL,
              ["http", "https", "file"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            throw ValidationError.invalidStreamURL(plan.stream.url)
        }
        let timeline = try PlaybackTimelineMapper(validating: plan.timeline)
        if let selectedIndex = plan.selectedTracks.audio?.index, selectedIndex < 0 {
            throw ValidationError.invalidAudioTrackIndex(selectedIndex)
        }

        self.planID = plan.planId
        self.sessionID = sessionID
        self.delivery = plan.delivery
        self.sourceURL = sourceURL
        self.timeline = timeline
        if let resumeSourcePosition, resumeSourcePosition.isFinite {
            vividStartPosition = timeline.playerPosition(forSourceTime: max(0, resumeSourcePosition))
        } else {
            vividStartPosition = timeline.vividStartPosition
        }
        self.audioSourceStreamIndex = audioSourceStreamIndex
        let isOriginalFile = plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP
        let isServerHLS = [
            PlaybackProtocolV3.PlanDelivery.remuxHLS,
            PlaybackProtocolV3.PlanDelivery.transcodeHLS,
        ].contains(plan.delivery)
        options = LoadOptions(
            httpHeaders: requestHeaders ?? plan.stream.headers,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode ?? VividDisplayContext.panelIsInHDRMode,
            audioOnly: plan.effectiveRecipe.videoCodec == nil,
            nativeRemoteHLS: isServerHLS,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            // The plan already chose the subtitle. Language preferences fed the
            // plan; they don't let the engine pick another track afterwards.
            nativeSubtitlePreferredLanguages: [],
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: [],
            // Lucid reads embedded subtitles straight from the source.
            externalSubtitles: [],
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            audioTrackOrdinal: isOriginalFile ? plan.selectedTracks.audio?.index : nil,
            managedHTTPReader: isOriginalFile
        )
    }

    /// The headers a subtitle file request may carry: all of them on a
    /// trusted origin, none elsewhere or for a local file. Origins compare
    /// with implicit ports normalised (through `StreamRequest`), so
    /// `https://host` and `https://host:443` match and a same-origin sidecar
    /// keeps its bearer.
    static func subtitleRequestHeaders(
        _ headers: [String: String],
        resourceURL: URL,
        trustedOriginURLs: [URL]
    ) -> [String: String] {
        guard !resourceURL.isFileURL else { return [:] }
        let isTrustedOrigin = trustedOriginURLs.contains { trustedURL in
            !trustedURL.isFileURL && StreamRequest.hasSameOrigin(resourceURL, trustedURL)
        }
        return isTrustedOrigin ? headers : [:]
    }
}
