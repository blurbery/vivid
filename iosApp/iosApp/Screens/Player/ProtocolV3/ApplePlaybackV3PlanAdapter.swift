import Foundation

/// A Protocol V3 plan with the attempt it belongs to.
struct PreparedPlaybackV3: Equatable {
    let playbackAttemptId: String
    let planAttemptId: String
    let planAttemptKey: String
    let outputContextId: String?
    let serverFeatures: [String]
    /// Whether this attempt negotiated `authorized_media_origins_v1`. Only an
    /// attempt that did may resolve absolute proxy-origin media URLs; the flag
    /// is fixed for the attempt and repeated unchanged across replans.
    var negotiatedAuthorizedMediaOrigins: Bool = false
    let plan: PlaybackV3Plan
}

enum ApplePlaybackV3PlanError: LocalizedError, Equatable {
    case unsupportedDelivery(String)
    case invalidTransport(String)
    case unsupportedClientTransformation(String)
    case invalidClientTransformation(String)
    case unsupportedRuntimeCorrection(String)
    case invalidEmbeddedSubtitle(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDelivery(let value):
            return "The server selected an unsupported V3 delivery: \(value)."
        case .invalidTransport(let value):
            return "The V3 playback transport is invalid: \(value)."
        case .unsupportedClientTransformation(let value):
            return "The V3 plan requires an unsupported client transformation: \(value)."
        case .invalidClientTransformation(let value):
            return "The V3 client transformation cannot be executed as planned: \(value)."
        case .invalidEmbeddedSubtitle(let value):
            return "The embedded subtitle selection is invalid: \(value)."
        case .unsupportedRuntimeCorrection(let value):
            return "The V3 plan requires an unsupported runtime correction: \(value)."
        }
    }
}

/// Checks Protocol V3 plans against what the Apple apps can play, and maps
/// them onto the player's session, picker and subtitle identities.
enum ApplePlaybackV3PlanAdapter {
    /// Recipes Lucid runs itself on an `original_http` load. Choosing one
    /// doesn't change how the load is issued (Lucid works the route out from
    /// the bitstream and the live panel), so validation only checks the
    /// server picked one this build can honour.
    private static let clientTransformations = ["client_dv7_to_dv81", "client_dv7_to_hdr10"]

    /// Throws unless the plan's delivery, transport, client transformation
    /// (at most one, on `original_http`), embedded subtitle and runtime
    /// corrections (none) are all ones this client can carry out.
    static func validate(_ plan: PlaybackV3Plan) throws {
        guard PlaybackProtocolV3.PlanDelivery.supported.contains(plan.delivery) else {
            throw ApplePlaybackV3PlanError.unsupportedDelivery(plan.delivery)
        }
        guard !plan.stream.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlaybackV3PlanError.invalidTransport("empty stream URL")
        }
        guard ["none", "session"].contains(plan.stream.headerRefresh) else {
            throw ApplePlaybackV3PlanError.invalidTransport(
                "unsupported header refresh mode \(plan.stream.headerRefresh)"
            )
        }
        if plan.stream.protocol == "hls" {
            guard plan.delivery == "server_remux_hls" || plan.delivery == "server_transcode_hls" else {
                throw ApplePlaybackV3PlanError.invalidTransport("HLS protocol/delivery mismatch")
            }
        } else if plan.stream.protocol == "http_progressive" {
            guard plan.delivery == "original_http" || plan.delivery == "server_remux_progressive" else {
                throw ApplePlaybackV3PlanError.invalidTransport("progressive protocol/delivery mismatch")
            }
        } else {
            throw ApplePlaybackV3PlanError.invalidTransport("unsupported protocol \(plan.stream.protocol)")
        }
        if let unsupported = plan.transformations.first(where: {
            $0.executor == "client" && !clientTransformations.contains($0.name)
        }) {
            throw ApplePlaybackV3PlanError.unsupportedClientTransformation(unsupported.name)
        }
        let selectedClientTransformations = plan.transformations.filter { $0.executor == "client" }
        if selectedClientTransformations.count > 1 {
            throw ApplePlaybackV3PlanError.invalidClientTransformation(
                "multiple mutually exclusive client transformations"
            )
        }
        if !selectedClientTransformations.isEmpty && plan.delivery != "original_http" {
            throw ApplePlaybackV3PlanError.invalidClientTransformation(
                "client transformations require the original_http delivery"
            )
        }
        if let embedded = plan.subtitle.embedded {
            guard plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP,
                  plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.render,
                  plan.subtitle.artifact == nil,
                  embedded.streamIndex >= 0,
                  embedded.streamIndex <= Int(Int32.max),
                  let selected = plan.selectedSubtitleInventoryItem,
                  selected.trackId == plan.subtitle.trackId,
                  selected.trackId == plan.selectedTracks.subtitle?.id,
                  plan.selectedTracks.subtitle?.index == nil || plan.selectedTracks.subtitle?.index == selected.combinedIndex,
                  selected.source == "embedded",
                  let codec = selected.codec,
                  let container = plan.stream.container,
                  ApplePlaybackV3Capabilities.nativeEmbeddedSubtitleCapabilities(
                    containers: [container]
                  ).contains(where: { $0.codecs.contains(ApplePlaybackV3Capabilities.normalizedSubtitleCodec(codec)) }) else {
                throw ApplePlaybackV3PlanError.invalidEmbeddedSubtitle("unsupported source, codec, or stream identity")
            }
        }
        if let correction = plan.runtimeCorrections.first {
            // Lucid handles media transport internally and does not apply
            // server-issued runtime correction tokens.
            throw ApplePlaybackV3PlanError.unsupportedRuntimeCorrection(correction)
        }
    }

    static func playbackSession(
        plan: PlaybackV3Plan,
        sessionId: String,
        selectedVersion: FileVersion,
        serverFeatures: [String]
    ) -> PlaybackSessionResponse {
        var subtitleUrls = plan.subtitle.inventory.compactMap { item -> SubtitleUrl? in
            guard item.delivery == "sidecar",
                  let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return nil
            }
            return SubtitleUrl(
                index: item.combinedIndex,
                language: item.language,
                codec: item.codec,
                label: item.label,
                source: item.source,
                forced: item.forced,
                default: item.default,
                hearingImpaired: item.hearingImpaired,
                fontBundleUrl: item.fontBundleUrl,
                url: url
            )
        }
        // The inventory is authoritative. A narrow fallback keeps the selected
        // sidecar artefact when a transitional server left its inventory URL
        // out, so an otherwise playable plan doesn't lose its subtitle.
        if let artifact = plan.subtitle.artifact,
           let selectedIndex = plan.selectedSubtitleCombinedIndex,
           !subtitleUrls.contains(where: { $0.index == selectedIndex }) {
            // Describe the track from its own inventory entry when there is
            // one (a `burn_in_only` entry has no URL but the right identity),
            // and from the counted catalogue only when there isn't.
            let published = plan.selectedSubtitleInventoryItem
            let selected = published == nil
                ? subtitleTrack(atServerCombinedIndex: selectedIndex, in: selectedVersion)
                : nil
            subtitleUrls.append(SubtitleUrl(
                index: selectedIndex,
                language: published?.language ?? selected?.language,
                codec: artifact.format,
                label: published?.label ?? selected?.title,
                source: published?.source
                    ?? selected.map { $0.external == true ? "external" : "embedded" }
                    ?? "protocol_v3",
                forced: published?.forced ?? selected?.forced,
                default: published?.default ?? selected?.isDefault,
                hearingImpaired: published?.hearingImpaired ?? selected?.hearingImpaired,
                fontBundleUrl: published?.fontBundleUrl,
                url: artifact.url
            ))
        }
        let durationSeconds: Double?
        if serverFeatures.contains(PlaybackProtocolV3.planSourceDurationFeature) {
            // Presence of the feature makes nil authoritative: the server
            // knows the field but could not determine this source's runtime.
            durationSeconds = plan.source.durationSeconds
        } else {
            // Transitional servers predate the field, so the catalog value is
            // still the only duration evidence available.
            durationSeconds = plan.source.durationSeconds ?? selectedVersion.duration
        }
        return PlaybackSessionResponse(
            sessionId: sessionId,
            userId: nil,
            profileId: nil,
            mediaFileId: plan.effectiveMediaFileId,
            playMethod: deliveryStrategy(plan.delivery).name,
            position: max(0, plan.timeline.playerStartSeconds),
            isPaused: false,
            streamUrl: plan.stream.url,
            audioTrackIndex: plan.selectedTracks.audio?.index,
            durationSeconds: durationSeconds,
            timelineOffsetSeconds: max(0, plan.timeline.timelineOffsetSeconds),
            subtitleUrls: subtitleUrls,
            playbackInfo: PlaybackInfo(
                streamType: plan.stream.protocol,
                transcodeAudio: plan.transformations.contains { $0.name == "audio_to_aac" },
                videoCodec: plan.effectiveRecipe.videoCodec,
                audioCodec: plan.effectiveRecipe.audioCodec
            )
        )
    }

    /// The engine's audio tracks when it lists any. A packaged V3 route only
    /// exposes its one rendition, so the picker then lists the catalogue's
    /// tracks instead: changing audio there is a server replan, so each row
    /// carries its catalogue ordinal in `srcId` and the plan's ordinal is
    /// ticked.
    static func audioPickerTracks(
        vividTracks: [PlayerTrack],
        plan: PlaybackV3Plan?,
        version: FileVersion?
    ) -> [PlayerTrack] {
        guard vividTracks.isEmpty,
              let plan,
              let version else {
            return vividTracks
        }
        let selectedOrdinal = plan.selectedTracks.audio?.index
        return (version.audioTracks ?? []).enumerated().map { ordinal, track in
            PlayerTrack(
                trackId: Int64(ordinal),
                kind: .audio,
                title: track.title,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: track.channels,
                bitrate: track.bitrate.map(Int64.init),
                isDefault: track.isDefault ?? false,
                isForced: false,
                isHearingImpaired: false,
                isExternal: false,
                isSelected: ordinal == selectedOrdinal,
                ffIndex: track.index,
                srcId: ordinal
            )
        }
    }

    /// V3 subtitle identities are external-first combined ordinals. The
    /// embedded picker carries FFmpeg stream indexes instead, and the watch
    /// detail lists embedded tracks before external ones, so the wire
    /// identity has to be translated rather than copied.
    ///
    /// This overload counts the catalogue's external tracks to find the
    /// embedded base, which the contract forbids: the combined space also
    /// holds stored subtitles the catalogue never lists, and a `burn_in_only`
    /// track still takes its ordinal. It's only right before any plan exists
    /// (the first start, with no inventory to read). Use the `inventory:`
    /// overload whenever there's a plan.
    static func serverCombinedSubtitleIndex(
        ffmpegStreamIndex: Int,
        in version: FileVersion
    ) -> Int? {
        guard let embeddedOrdinal = embeddedSubtitleOrdinal(
            ffmpegStreamIndex: ffmpegStreamIndex,
            in: version
        ) else {
            return nil
        }
        let externalCount = (version.subtitleTracks ?? []).filter { $0.external == true }.count
        return externalCount + embeddedOrdinal
    }

    /// Resolves an embedded FFmpeg stream index against the server's published
    /// combined ordinals instead of deriving one.
    ///
    /// The inventory's `embedded` entries are in container stream order, as
    /// the catalogue lists them, so the *n*-th embedded catalogue track is the
    /// *n*-th embedded inventory entry, which carries the authoritative
    /// `combined_index`. An empty inventory means no plan has published one
    /// yet, so the counted version stands in.
    static func serverCombinedSubtitleIndex(
        ffmpegStreamIndex: Int,
        in version: FileVersion,
        inventory: [PlaybackV3SubtitleInventoryItem]
    ) -> Int? {
        guard !inventory.isEmpty else {
            return serverCombinedSubtitleIndex(ffmpegStreamIndex: ffmpegStreamIndex, in: version)
        }
        guard let embeddedOrdinal = embeddedSubtitleOrdinal(
            ffmpegStreamIndex: ffmpegStreamIndex,
            in: version
        ) else {
            return nil
        }
        let embeddedInventory = inventory.filter { $0.source == "embedded" }
        guard embeddedInventory.indices.contains(embeddedOrdinal) else { return nil }
        return embeddedInventory[embeddedOrdinal].combinedIndex
    }

    static func serverCombinedSubtitleIndex(
        for playerTrack: PlayerTrack,
        in version: FileVersion
    ) -> Int? {
        serverCombinedSubtitleIndex(for: playerTrack, in: version, inventory: [])
    }

    static func serverCombinedSubtitleIndex(
        for playerTrack: PlayerTrack,
        in version: FileVersion,
        inventory: [PlaybackV3SubtitleInventoryItem]
    ) -> Int? {
        if SubtitleTrackIdSpace.isSidecar(playerTrack.trackId) || playerTrack.isExternal {
            // A sidecar track comes from a published `SubtitleUrl`, whose
            // `index` is the server's combined ordinal. Echo it; mapping it
            // through the inventory's positions would be wrong.
            return playerTrack.srcId.flatMap { $0 >= 0 ? $0 : nil }
        }
        guard let ffmpegStreamIndex = playerTrack.ffIndex else { return nil }
        return serverCombinedSubtitleIndex(
            ffmpegStreamIndex: ffmpegStreamIndex,
            in: version,
            inventory: inventory
        )
    }

    /// Inverse of `serverCombinedSubtitleIndex`. Same caveat: the counted base
    /// is only sound before a plan publishes an inventory.
    static func ffmpegSubtitleStreamIndex(
        serverCombinedIndex: Int,
        in version: FileVersion
    ) -> Int? {
        guard serverCombinedIndex >= 0 else { return nil }
        let tracks = version.subtitleTracks ?? []
        let externalCount = tracks.filter { $0.external == true }.count
        let embedded = tracks.filter { $0.external != true }
        let embeddedOrdinal = serverCombinedIndex - externalCount
        guard embedded.indices.contains(embeddedOrdinal) else { return nil }
        return embedded[embeddedOrdinal].selectionIndex
    }

    static func ffmpegSubtitleStreamIndex(
        serverCombinedIndex: Int,
        in version: FileVersion,
        inventory: [PlaybackV3SubtitleInventoryItem]
    ) -> Int? {
        guard !inventory.isEmpty else {
            return ffmpegSubtitleStreamIndex(serverCombinedIndex: serverCombinedIndex, in: version)
        }
        let embeddedInventory = inventory.filter { $0.source == "embedded" }
        guard let embeddedOrdinal = embeddedInventory.firstIndex(where: {
            $0.combinedIndex == serverCombinedIndex
        }) else {
            // Not an embedded track: external and downloaded ordinals have no
            // FFmpeg stream to select.
            return nil
        }
        let embedded = (version.subtitleTracks ?? []).filter { $0.external != true }
        guard embedded.indices.contains(embeddedOrdinal) else { return nil }
        return embedded[embeddedOrdinal].selectionIndex
    }

    /// Position of an FFmpeg stream index among the version's embedded subtitle
    /// tracks, in container stream order.
    private static func embeddedSubtitleOrdinal(
        ffmpegStreamIndex: Int,
        in version: FileVersion
    ) -> Int? {
        guard ffmpegStreamIndex >= 0 else { return nil }
        let embedded = (version.subtitleTracks ?? []).filter { $0.external != true }
        return embedded.firstIndex { $0.selectionIndex == ffmpegStreamIndex }
    }

    private static func subtitleTrack(
        atServerCombinedIndex index: Int,
        in version: FileVersion
    ) -> SubtitleTrack? {
        guard index >= 0 else { return nil }
        let tracks = version.subtitleTracks ?? []
        let external = tracks.filter { $0.external == true }
        let embedded = tracks.filter { $0.external != true }
        let combined = external + embedded
        guard combined.indices.contains(index) else { return nil }
        return combined[index]
    }

    private static func deliveryStrategy(_ value: String) -> PlaybackDeliveryStrategy {
        switch value {
        case "server_remux_hls", "server_remux_progressive":
            return .remux
        case "server_transcode_hls":
            return .transcode
        default:
            return .direct
        }
    }
}
