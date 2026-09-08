import VividKit
import Foundation

enum VividInitialAudioPreference {
    /// Local language preference wins over another client's saved server choice.
    static func selectedOrdinal(manual: Int?, tracks: [AudioTrack], preferredLanguage: String) -> Int? {
        if let manual { return manual }
        guard !tracks.isEmpty else { return nil }
        let language = preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = tracks.indices.filter { index in
            guard !language.isEmpty, let candidate = tracks[index].language else { return false }
            return SubtitleAutoResolver.languagesMatch(candidate, language)
        }
        let defaultIndex = matching.first(where: { tracks[$0].isDefault == true }) ?? matching.first
            ?? tracks.firstIndex(where: { $0.isDefault == true }) ?? 0
        let selectedLanguage = tracks[defaultIndex].language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = matching.isEmpty ? tracks.indices.filter { index in
            let candidate = tracks[index].language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return selectedLanguage.isEmpty ? candidate.isEmpty
                : SubtitleAutoResolver.languagesMatch(candidate, selectedLanguage)
        } : matching
        let compatible = candidates.filter { index in
            let codec = tracks[index].codec?.lowercased() ?? ""
            let title = ((tracks[index].title ?? "") + " " + (tracks[index].embeddedTitle ?? "")).lowercased()
            return (["aac", "ac3", "eac3", "mp3", "alac", "flac"].contains(codec) || codec.hasPrefix("pcm"))
                && !title.contains("commentary")
        }
        if compatible.contains(defaultIndex) { return defaultIndex }
        return compatible.first(where: { tracks[$0].isDefault == true }) ?? compatible.first ?? defaultIndex
    }

    static func languages(
        selectedOrdinal: Int?,
        tracks: [AudioTrack],
        fallbackLanguage: String
    ) -> [String] {
        if let selectedOrdinal {
            guard tracks.indices.contains(selectedOrdinal) else { return [] }
            let selectedLanguage = tracks[selectedOrdinal].language?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return selectedLanguage.isEmpty ? [] : [selectedLanguage]
        }

        let fallback = fallbackLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [] : [fallback]
    }

}

/// Decides whether a committed Vivid load failed because the bearer frozen
/// into its media request expired, and whether rebuilding it would actually
/// install a different credential.
///
/// Keep this typed and token-agnostic: AVFoundation localizes its messages,
/// while the error domain/code and Vivid's source-refusal status are stable.
/// Comparing the complete header value bounds recovery to one reload per
/// credential generation; a revoked current token falls through to the normal
/// Protocol V3 route ladder instead of looping on the same URL forever.
enum VividAuthenticationRecoveryPolicy {
    static func isExpiredBearerFailure(_ failure: PlaybackErrorInfo) -> Bool {
        if failure.kind == .sourceRefused {
            return failure.underlyingDomain == nil && failure.underlyingCode == 401
        }
        return failure.kind == .nativeItemFailed
            && failure.underlyingDomain == NSURLErrorDomain
            && failure.underlyingCode == NSURLErrorUserAuthenticationRequired
    }

    static func shouldReload(
        failedHeaders: [String: String],
        refreshedHeaders: [String: String]
    ) -> Bool {
        guard let refreshed = authorizationHeader(in: refreshedHeaders) else { return false }
        return authorizationHeader(in: failedHeaders) != refreshed
    }

    static func shouldReloadAfterProgress(
        _ result: PlaybackProgressReportResult,
        activeHeaders: [String: String],
        currentHeaders: [String: String]
    ) -> Bool {
        result == .success && shouldReload(
            failedHeaders: activeHeaders,
            refreshedHeaders: currentHeaders
        )
    }

    private static func authorizationHeader(in headers: [String: String]) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare("Authorization") == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Immutable inputs for one Vivid load generation.
///
/// The initialisers are main-actor isolated because they sample the display
/// before building `LoadOptions`: Vivid runs the display-criteria handshake
/// synchronously inside `load`, so `panelIsInHDRMode` and `matchContentEnabled`
/// have to be true of the panel at spec-construction time. Passing an explicit
/// `panelIsInHDRMode` overrides that measurement; `nil` means measure now.
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
    /// Player-axis position handed to `VividEngine.load`. Usually the plan's
    /// declared start, but a same-plan credential reload resumes at the current
    /// source position translated through the still-active timeline.
    let vividStartPosition: Double
    let options: LoadOptions
    let audioSourceStreamIndex: Int32?

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
        let externalSubtitles: [ExternalSubtitleTrack] = []

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
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            audioTrackOrdinal: audioTrackOrdinal
        )
    }

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
        let externalSubtitles: [ExternalSubtitleTrack] = []

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
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false
        )
    }

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
        let resolvedPlanSourceURL: URL?
        if let resolveURL {
            resolvedPlanSourceURL = resolveURL(plan.stream.url)
        } else {
            resolvedPlanSourceURL = URL(string: plan.stream.url)
        }
        guard let sourceURL = sourceURLOverride ?? resolvedPlanSourceURL,
              ["http", "https", "file"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            throw ValidationError.invalidStreamURL(plan.stream.url)
        }
        let timeline = try PlaybackTimelineMapper(validating: plan.timeline)
        // `StreamRequest` adds the current server bearer to the plan-provided
        // headers. Its merged value is authoritative for both the media and
        // same-origin subtitle artifacts; falling back to the wire-plan value
        // keeps the pure mapper independently usable in tests.
        let effectiveHeaders = requestHeaders ?? plan.stream.headers

        if let selectedIndex = plan.selectedTracks.audio?.index {
            guard selectedIndex >= 0 else {
                throw ValidationError.invalidAudioTrackIndex(selectedIndex)
            }
        }

        // VividKit reads embedded subtitles directly from the media source.
        let externalSubtitles: [ExternalSubtitleTrack] = []

        self.planID = plan.planId
        self.sessionID = sessionID
        self.delivery = plan.delivery
        self.sourceURL = sourceURL
        self.timeline = timeline
        if let resumeSourcePosition, resumeSourcePosition.isFinite {
            vividStartPosition = timeline.playerPosition(
                forSourceTime: max(0, resumeSourcePosition)
            )
        } else {
            vividStartPosition = timeline.vividStartPosition
        }
        self.audioSourceStreamIndex = audioSourceStreamIndex
        let isServerHLS = [
            PlaybackProtocolV3.PlanDelivery.remuxHLS,
            PlaybackProtocolV3.PlanDelivery.transcodeHLS,
        ].contains(plan.delivery)
        options = LoadOptions(
            httpHeaders: effectiveHeaders,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode ?? VividDisplayContext.panelIsInHDRMode,

            audioOnly: plan.effectiveRecipe.videoCodec == nil,
            nativeRemoteHLS: isServerHLS,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            // V3 already selected one exact artifact. Language preference is
            // planning input, not permission for the engine to select a
            // different embedded or inventory track after the plan arrives.
            nativeSubtitlePreferredLanguages: [],
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: [],
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            audioTrackOrdinal: plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP
                ? plan.selectedTracks.audio?.index : nil
        )
    }

    static func subtitleRequestHeaders(
        _ headers: [String: String],
        resourceURL: URL,
        trustedOriginURLs: [URL]
    ) -> [String: String] {
        guard !resourceURL.isFileURL else {
            return [:]
        }
        // Origin equality has to normalize the implicit ports, or
        // `https://host/media` and `https://host:443/subtitles` read as
        // different origins and the bearer is stripped from a sidecar that is
        // genuinely same-origin (Vivid then gets a 401). `StreamRequest`
        // already owns that comparison for the media URL itself; sharing it
        // keeps the two boundaries from drifting apart.
        let isTrustedOrigin = trustedOriginURLs.contains { trustedURL in
            !trustedURL.isFileURL && StreamRequest.hasSameOrigin(resourceURL, trustedURL)
        }
        return isTrustedOrigin ? headers : [:]
    }
}
