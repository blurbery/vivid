import Foundation

/// The settings contract's two quality values, and the translation between
/// them and the single quality id the Apple pickers use.
///
/// The contract has no compound quality: `playback.preferred_quality` is a
/// bare resolution (auto, 480p, 720p, 1080p, 2160p, original) and
/// `playback.max_bitrate_kbps` a separate nullable cap. Apple's rungs such as
/// `1080p-high` or `328p` are a bitrate written into the resolution, so they
/// are split here, which is also what lets a pair saved by the web or Android
/// clients read back correctly. The Apple ladder keeps its own rungs; the
/// clients agree on the stored values and each maps them onto its own rungs.
struct AppleQualityAxes: Equatable {
    /// A member of the contract's `playback.preferred_quality` enum.
    let resolution: String
    /// The `playback.max_bitrate_kbps` cap, or nil for uncapped.
    let bitrateKbps: Int?

    static let auto = AppleQualityAxes(resolution: "auto", bitrateKbps: nil)

    /// The contract's resolutions, most to least constrained.
    static let resolutionMembers = ["auto", "480p", "720p", "1080p", "2160p", "original"]

    /// Split one of this client's quality ids into the two values.
    ///
    /// `328p` predates the contract and has no member. It maps to `480p` and
    /// keeps its 700 kbps cap rather than widening to `auto`, which would
    /// uncap the tightest tier the viewer chose.
    static func split(_ qualityId: String) -> AppleQualityAxes {
        let normalized = ApplePlaybackQuality.normalizeStoredId(qualityId)
        if normalized == ApplePlaybackQuality.ultraHDId {
            return AppleQualityAxes(resolution: "2160p", bitrateKbps: nil)
        }
        guard let option = ApplePlaybackQuality.requestOptions.first(where: { $0.id == normalized }),
              !option.isAuto else {
            return .auto
        }
        if option.isOriginal {
            return AppleQualityAxes(resolution: "original", bitrateKbps: nil)
        }
        let resolution = resolutionMembers.contains(option.resolution) ? option.resolution : "480p"
        return AppleQualityAxes(resolution: resolution, bitrateKbps: option.bitrateKbps)
    }

    /// Join the two stored values into the id this client's pickers use.
    ///
    /// The resolution always wins: the id names the stored resolution, and
    /// the cap only picks which of its rungs (the highest within the cap, or
    /// the smallest when the cap is under all of them). V3 sends the
    /// resolution and cap as separate fields, so trading the resolution for a
    /// local rung would turn a shared "1080p at 6 Mbps" into 720p just
    /// because this ladder has no 1080p rung under 8 Mbps.
    ///
    /// `original` stays the uncapped source intent and `2160p` a
    /// resolution-only id. A member added by a newer server is Auto until
    /// this client knows it.
    static func join(resolution: String?, bitrateKbps: Int?) -> String {
        let resolution = (resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            .flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        switch resolution {
        case "original": return ApplePlaybackQuality.originalId
        // A cap with no resolution has no rung to name; the cap is still
        // sent separately.
        case "auto": return ApplePlaybackQuality.autoId
        case "2160p": return ApplePlaybackQuality.ultraHDId
        default: break
        }

        // Matched on each rung's contract resolution rather than its label,
        // so 328p (contract 480p) is a candidate for a stored 480p and round
        // trips. An unknown member matches nothing, which is Auto.
        let atResolution = ApplePlaybackQuality.tiers.filter { split($0.id).resolution == resolution }
        let byBitrate: (ApplePlaybackQualityOption, ApplePlaybackQualityOption) -> Bool = {
            $0.bitrateKbps < $1.bitrateKbps
        }
        guard !atResolution.isEmpty else { return ApplePlaybackQuality.autoId }
        guard let cap = bitrateKbps, cap > 0 else {
            return atResolution.max(by: byBitrate)?.id ?? ApplePlaybackQuality.autoId
        }
        if let withinCap = atResolution.filter({ $0.bitrateKbps <= cap }).max(by: byBitrate) {
            return withinCap.id
        }
        // The cap is under every rung. Keep the resolution the viewer asked
        // for with its smallest rung; the cap itself is sent with the request.
        return atResolution.min(by: byBitrate)?.id ?? ApplePlaybackQuality.autoId
    }

    /// The bandwidth cap for a load. An in-player choice replaces the saved
    /// cap with its rung's (Auto and Original clear it). Without one, the
    /// saved cap is used exactly, so a 1080p/6 Mbps pair from another client
    /// isn't widened to this ladder's 8 Mbps rung.
    static func resolvedBitrateCap(
        qualityOverride: String?,
        fallbackBitrateKbps: Int?
    ) -> Int? {
        if let qualityOverride {
            return split(qualityOverride).bitrateKbps
        }
        return fallbackBitrateKbps.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The bandwidth cap for a load that may carry the current playback's
    /// quality forward. A carried quality isn't a new choice, so its id
    /// isn't split again: it's often a bare resolution, which this ladder
    /// would turn into a cap playback never ran with (1080p into 10 Mbps).
    /// A carried cap only applies alongside an override.
    static func resolvedBitrateCap(
        qualityOverride: String?,
        carriedCap: CarriedBandwidthCap?,
        fallbackBitrateKbps: Int?
    ) -> Int? {
        guard qualityOverride != nil, let carriedCap else {
            return resolvedBitrateCap(qualityOverride: qualityOverride, fallbackBitrateKbps: fallbackBitrateKbps)
        }
        switch carriedCap {
        case .savedSetting:
            return resolvedBitrateCap(qualityOverride: nil, fallbackBitrateKbps: fallbackBitrateKbps)
        case .inEffect(let bitrateKbps):
            return bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

/// The bandwidth cap a playback ran with, so a load that carries its quality
/// forward (the next episode, or a retried, renewed or recovered session) can
/// repeat that cap exactly.
enum CarriedBandwidthCap: Equatable {
    /// Not known for this playback (an offline file, for example): use the
    /// saved Settings cap, as a start without an override would.
    case savedSetting
    /// The cap the playback was requested with; nil is uncapped.
    case inEffect(Int?)
}
