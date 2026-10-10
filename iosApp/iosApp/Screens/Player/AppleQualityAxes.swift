//
//  AppleQualityAxes.swift
//  Vivid (iOS + tvOS + macOS)
//
//  Translation between the single quality id the Apple UI picks from and the
//  two orthogonal values the settings contract stores.
//
//  The contract has no compound quality. `playback.preferred_quality` is an
//  enum of bare resolutions (auto, 480p, 720p, 1080p, 2160p, original) and
//  `playback.max_bitrate_kbps` is a separate nullable bandwidth cap. Apple's
//  ladder — "1080p-high", "720p-medium", "328p" — was never a third axis, only
//  a bitrate written into the resolution string, and the legacy string-only
//  registry stored it verbatim because it validated nothing.
//
//  The canonical endpoint does validate, so sending "1080p-high" now fails the
//  enum with `invalid_value`. Splitting it here is what keeps the preference
//  syncing at all — and it is also what lets a quality chosen on the web or on
//  Android read back correctly here, since those clients have always stored the
//  two axes (web/src/lib/qualityPresets.ts, Android's QualityPresets.kt).
//
//  The Apple bitrate ladder deliberately stays as it is rather than being
//  retuned to match the web's presets: the tiers are what the in-player
//  switcher already offers. The clients agree on the stored *axes*; each
//  client may map those axes onto its own playback rungs without changing the
//  authored resolution or bitrate cap.
//
//  Because the ladders differ, rejoining has to decide what to do with a pair
//  that lands between two Apple rungs. The resolution wins — see ``join``. The
//  bitrate axis is not lost; it is carried separately to the one request shape
//  that can express it.
//

import Foundation

/// The contract's two quality axes, as one value.
struct AppleQualityAxes: Equatable {
    /// A member of the contract's `playback.preferred_quality` enum.
    let resolution: String
    /// The `playback.max_bitrate_kbps` cap, or nil for uncapped.
    let bitrateKbps: Int?

    static let auto = AppleQualityAxes(resolution: "auto", bitrateKbps: nil)

    /// Contract enum members, most to least constrained.
    static let resolutionMembers = ["auto", "480p", "720p", "1080p", "2160p", "original"]

    /// Split one of this client's stored quality ids into the two axes.
    ///
    /// `328p` has no enum member — it predates the contract's ladder. It maps
    /// to `480p` and keeps its 700 kbps cap on the bitrate axis rather than
    /// widening to `auto`: the user asked for the tightest tier, and dropping
    /// the cap would silently uncap their connection.
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

    /// Recompose the two stored axes into the id this client's pickers use.
    ///
    /// The **resolution axis is authoritative**: the returned tier always names
    /// the resolution that was stored. The bitrate axis only chooses *which
    /// rung of that resolution* — the highest one within the cap, or the
    /// smallest one when the cap sits under all of them.
    ///
    /// It has to work that way because V3 sends the bare resolution and bitrate
    /// cap as separate request fields. A join that traded the resolution away
    /// to fit Apple's local rung table would still change a shared "1080p at
    /// 6 Mbps" preference into 720p. Apple's ladder simply has no 1080p rung
    /// below 8 Mbps; that is a fact about this client's table, not the user's
    /// authored resolution.
    ///
    /// The cap is not discarded. It is applied where it is actually
    /// expressible: ``ApplePlaybackQuality/targetBitrateKbps(for:selectedVersion:capKbps:)``
    /// and ``ApplePlaybackQuality/shouldForceTranscode(preferredQualityId:selectedVersion:capKbps:)``
    /// clamp the legacy `/transcode/start` encode target to it, so a stored
    /// 6 Mbps cap transcodes 1080p at 6 Mbps rather than at the rung's 8.
    ///
    /// `original` remains the uncapped source-resolution intent; when paired
    /// with a numeric bandwidth cap, the legacy planner still re-encodes to
    /// honour that independent axis. The contract's 2160p member is preserved
    /// as an opaque resolution-only id even though Apple's local transcode
    /// ladder has no fabricated 4K bitrate rung. A member added by a newer
    /// server still falls back to `auto` until this client knows it.
    static func join(resolution: String?, bitrateKbps: Int?) -> String {
        let resolution = (resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "auto"
        if resolution == "original" {
            return ApplePlaybackQuality.originalId
        }
        if resolution == "auto" {
            // A bandwidth cap with no resolution cap has no tier to name: this
            // client's picker is keyed on the resolution axis. The cap remains
            // independent and is sent to V3 or enforced by the legacy planner.
            return ApplePlaybackQuality.autoId
        }
        if resolution == "2160p" {
            return ApplePlaybackQuality.ultraHDId
        }

        // Matched on each tier's *contract* resolution rather than its own
        // label, so 328p — whose contract member is 480p — stays a candidate
        // for a stored 480p and round-trips instead of widening to the 480p
        // tier above it. Any member this build has never seen matches nothing,
        // which is the `auto` fallback.
        let atResolution = ApplePlaybackQuality.tiers.filter {
            split($0.id).resolution == resolution
        }
        guard !atResolution.isEmpty else { return ApplePlaybackQuality.autoId }

        guard let cap = bitrateKbps, cap > 0 else {
            // Uncapped: the best rung this resolution offers.
            return atResolution.max(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
                ?? ApplePlaybackQuality.autoId
        }
        if let withinCap = atResolution.filter({ $0.bitrateKbps <= cap })
            .max(by: { $0.bitrateKbps < $1.bitrateKbps }) {
            return withinCap.id
        }
        // The cap is under every rung this resolution has. The resolution is
        // still what the user asked for and what the request carries, so keep
        // it and take the smallest rung; the cap itself is enforced at request
        // time rather than by silently shrinking the picture.
        return atResolution.min(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
            ?? ApplePlaybackQuality.autoId
    }

    /// Resolve the bandwidth half of the active playback intent.
    ///
    /// An in-player selection is a complete temporary override, so its local
    /// tier replaces the fallback cap (including Auto/Original clearing it).
    /// With no override, the exact fallback survives untouched. That distinction
    /// matters for pairs authored by another client: Apple's local 1080p rung is
    /// 8 Mbps, so splitting a stored 1080p/6 Mbps pair would silently widen it.
    static func resolvedBitrateCap(
        qualityOverride: String?,
        fallbackBitrateKbps: Int?
    ) -> Int? {
        if let qualityOverride {
            return split(qualityOverride).bitrateKbps
        }
        return fallbackBitrateKbps.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Resolve the bandwidth cap for a load that may carry the current
    /// playback's quality forward instead of a fresh in-player choice.
    ///
    /// A carried override is not a new choice, so its id must not be split
    /// again: the active quality is often a bare resolution, and this client's
    /// tier table would turn a 1080p preference into a 10 Mbps cap (or Auto on
    /// a 720p file into 2 Mbps) that playback never ran with. A carried cap only
    /// applies alongside an override; without one the load is an ordinary start.
    static func resolvedBitrateCap(
        qualityOverride: String?,
        carriedCap: CarriedBandwidthCap?,
        fallbackBitrateKbps: Int?
    ) -> Int? {
        guard qualityOverride != nil, let carriedCap else {
            return resolvedBitrateCap(
                qualityOverride: qualityOverride,
                fallbackBitrateKbps: fallbackBitrateKbps
            )
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
    /// Not known for this playback (for example an offline file): use the
    /// saved Settings cap, as a start without an override would.
    case savedSetting
    /// The cap the playback was requested with; nil is uncapped.
    case inEffect(Int?)
}
