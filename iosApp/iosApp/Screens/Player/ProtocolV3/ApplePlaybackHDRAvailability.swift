import AVFoundation

/// The HDR modes the current output reports, used only to describe the
/// device in Protocol V3 capabilities and diagnostics. Lucid Engine owns the
/// display criteria and the media route.
struct ApplePlaybackHDRAvailability: Equatable {
    let hdrPlaybackEligible: Bool
    let supportsHDR10: Bool
    let supportsHLG: Bool
    let supportsDolbyVision: Bool

    /// The simulator reports no HDR at all.
    static func probe() -> ApplePlaybackHDRAvailability {
        #if targetEnvironment(simulator)
        return ApplePlaybackHDRAvailability(
            hdrPlaybackEligible: false,
            supportsHDR10: false,
            supportsHLG: false,
            supportsDolbyVision: false
        )
        #else
        let modes = AVPlayer.availableHDRModes
        return ApplePlaybackHDRAvailability(
            hdrPlaybackEligible: AVPlayer.eligibleForHDRPlayback,
            supportsHDR10: modes.contains(.hdr10),
            supportsHLG: modes.contains(.hlg),
            supportsDolbyVision: modes.contains(.dolbyVision)
        )
        #endif
    }
}
