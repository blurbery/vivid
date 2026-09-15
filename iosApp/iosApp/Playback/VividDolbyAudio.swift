// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation

/// Source metadata only. Output routing is reported independently.
struct VividDolbyAudio {
    enum Format: String {
        case aac, ac3, eac3, dts, trueHD = "truehd", pcm, unknown
        case eac3JOC = "eac3_joc_atmos"
    }

    enum Evidence: String { case streamProfile = "stream_profile", decodedProfile = "decoded_profile" }
    // Public FFmpeg AV_PROFILE_EAC3_DDP_ATMOS, not a channel-count or filename heuristic.
    static let eac3JOCProfile: Int32 = 30
    let format: Format
    let profile: Int32?
    let evidence: Evidence

    init(codec: String, profile: Int32?, evidence: Evidence) {
        self.profile = profile
        self.evidence = evidence
        switch codec.lowercased() {
        case "aac": format = .aac
        case "ac3": format = .ac3
        case "eac3": format = profile == Self.eac3JOCProfile ? .eac3JOC : .eac3
        case "dts": format = .dts
        case "truehd": format = .trueHD
        case let name where name.hasPrefix("pcm_"): format = .pcm
        default: format = .unknown
        }
    }

    var joc: String {
        format == .eac3JOC ? "confirmed" : format == .eac3 ? "unconfirmed" : "not_applicable"
    }

    /// A later frame without signalling does not undo positive JOC evidence in this stream.
    func retainingJOC(from previous: VividDolbyAudio?) -> VividDolbyAudio {
        if format == .eac3, previous?.format == .eac3JOC, let previous { return previous }
        return self
    }

    var diagnosticFields: String {
        "source_format=\(format.rawValue) codec_profile=\(profile.map(String.init) ?? "unknown") " +
        "joc=\(joc) evidence=\(evidence.rawValue)"
    }
}
