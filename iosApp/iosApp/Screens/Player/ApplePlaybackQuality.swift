import Foundation

enum PlaybackFallbackMode: String, CaseIterable {
    case ultraHD = "vivid-2160p"
    case fullHD = "vivid-1080p"
    case hd = "vivid-720p"

    var resolution: String {
        switch self {
        case .ultraHD: "2160p"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }
    var label: String { self == .ultraHD ? "4K" : resolution }
    var maximumKbps: Int {
        switch self {
        case .ultraHD: 80_000
        case .fullHD: 10_000
        case .hd: 4_000
        }
    }
    var fallbackKbps: Int {
        switch self {
        case .ultraHD: 20_000
        case .fullHD: 4_000
        case .hd: 1_500
        }
    }
    var fallbackID: String { rawValue + "-fallback" }
    var detail: String {
        let bitrate = ApplePlaybackQuality.formatBitrate(kbps: fallbackKbps)
        return String(localized: "If buffering: up to \(bitrate).", comment: "Quality option detail: the bitrate it drops to while buffering")
    }
    var option: ApplePlaybackQualityOption {
        .init(id: rawValue, label: label, resolution: resolution, bitrateKbps: maximumKbps,
              isOriginal: false, isAuto: false)
    }
    var fallbackOption: ApplePlaybackQualityOption {
        .init(id: fallbackID, label: label, resolution: resolution, bitrateKbps: fallbackKbps,
              isOriginal: false, isAuto: false)
    }
    var preset: VividQualityPreset {
        .init(id: rawValue, label: label, description: detail, resolution: resolution,
              bitrateKbps: maximumKbps)
    }
    static func matching(_ id: String?) -> Self? {
        allCases.first { $0.rawValue == id || $0.fallbackID == id }
    }
    func isActive(qualityID: String) -> Bool { Self.matching(qualityID) == self }
}

struct PlaybackFallbackGate {
    static let delay: TimeInterval = 8
    private(set) var consumed = false
    private var bufferingSince: TimeInterval?

    mutating func update(buffering: Bool, eligible: Bool, now: TimeInterval) {
        guard buffering, eligible, !consumed else {
            bufferingSince = nil
            return
        }
        if bufferingSince == nil { bufferingSince = now }
    }
    mutating func consumeIfReady(now: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, !consumed, let start = bufferingSince,
              now - start >= Self.delay else { return false }
        consumed = true
        bufferingSince = nil
        return true
    }
}

struct ApplePlaybackQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: String
    let bitrateKbps: Int
    let isOriginal: Bool
    let isAuto: Bool

    var subtitle: String? {
        if let mode = PlaybackFallbackMode(rawValue: id) { return mode.detail }
        if isOriginal {
            return String(localized: "No transcoding; compatibility required.")
        }
        if isAuto {
            return String(localized: "Direct when possible; transcodes if needed.")
        }
        guard bitrateKbps > 0 else { return nil }
        return String(localized: "Up to \(bitrateLabel); may transcode.", comment: "Quality option detail, for example Up to 10 Mbps; may transcode.")
    }

    var bitrateLabel: String {
        ApplePlaybackQuality.formatBitrate(kbps: bitrateKbps)
    }

    var labelWithBitrate: String {
        if isAuto { return String(localized: "Auto (Recommended)") }
        if isOriginal { return String(localized: "Original Quality") }
        guard !isOriginal, !isAuto, bitrateKbps > 0 else { return label }
        return String(localized: "\(label) (\(bitrateLabel))", comment: "Quality picker option: preset name and its bitrate, e.g. 1080p High (10 Mbps)")
    }
}

struct ApplePlaybackV3QualitySelection: Equatable {
    let clientQualityId: String
    let serverPreference: String
    let bandwidthCapKbps: Int?
    let isServerOwned: Bool
}

enum ApplePlaybackQuality {
    static let autoId = "auto"
    static let originalId = "original"
    /// Contract-supported resolution with no fabricated local bitrate rung.
    static let ultraHDId = "2160p"

    static let original = ApplePlaybackQualityOption(
        id: originalId,
        label: String(localized: "Original"),
        resolution: "",
        bitrateKbps: 0,
        isOriginal: true,
        isAuto: false
    )

    static let auto = ApplePlaybackQualityOption(
        id: autoId,
        label: String(localized: "Auto"),
        resolution: "",
        bitrateKbps: 0,
        isOriginal: false,
        isAuto: true
    )

    /// A contract resolution cap without an invented bandwidth rung. A zero
    /// bitrate is a local sentinel for "uncapped" and is never sent as a cap.
    static let ultraHD = ApplePlaybackQualityOption(
        id: ultraHDId,
        label: "4K",
        resolution: ultraHDId,
        bitrateKbps: 0,
        isOriginal: false,
        isAuto: false
    )

    static let tiers: [ApplePlaybackQualityOption] = [
        .init(id: "1080p-high", label: String(localized: "Up to 1080p HD (High)"), resolution: "1080p", bitrateKbps: 20_000, isOriginal: false, isAuto: false),
        .init(id: "1080p-medium", label: String(localized: "Up to 1080p HD (Medium)"), resolution: "1080p", bitrateKbps: 12_000, isOriginal: false, isAuto: false),
        .init(id: "1080p", label: String(localized: "Up to 1080p HD"), resolution: "1080p", bitrateKbps: 10_000, isOriginal: false, isAuto: false),
        .init(id: "1080p-8", label: String(localized: "Up to 1080p HD"), resolution: "1080p", bitrateKbps: 8_000, isOriginal: false, isAuto: false),
        .init(id: "720p-high", label: String(localized: "Up to 720p HD (High)"), resolution: "720p", bitrateKbps: 4_000, isOriginal: false, isAuto: false),
        .init(id: "720p-medium", label: String(localized: "Up to 720p HD (Medium)"), resolution: "720p", bitrateKbps: 3_000, isOriginal: false, isAuto: false),
        .init(id: "720p", label: String(localized: "Up to 720p HD"), resolution: "720p", bitrateKbps: 2_000, isOriginal: false, isAuto: false),
        .init(id: "480p", label: String(localized: "Up to 480p"), resolution: "480p", bitrateKbps: 1_500, isOriginal: false, isAuto: false),
        .init(id: "328p", label: String(localized: "Up to 328p"), resolution: "328p", bitrateKbps: 700, isOriginal: false, isAuto: false),
    ]

    static let settingsOptions: [ApplePlaybackQualityOption] = [auto, original, ultraHD] + tiers
    static let requestOptions: [ApplePlaybackQualityOption] = settingsOptions
        + PlaybackFallbackMode.allCases.flatMap { [$0.option, $0.fallbackOption] }

    static func normalizeStoredId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch value {
        case "", autoId:
            return autoId
        case ultraHDId, "4k", "uhd":
            return ultraHDId
        case originalId:
            return originalId
        case "420p":
            return "328p"
        default:
            if requestOptions.contains(where: { $0.id == value }) {
                return value
            }
            return autoId
        }
    }

    static func displayName(for raw: String) -> String {
        let id = normalizeStoredId(raw)
        if id == ultraHDId { return "4K" }
        return requestOptions.first(where: { $0.id == id })?.label ?? id
    }

    static func displayNameWithBitrate(for raw: String) -> String {
        let id = normalizeStoredId(raw)
        if id == ultraHDId { return "4K" }
        return requestOptions.first(where: { $0.id == id })?.labelWithBitrate ?? id
    }

    /// Build the in-player menu from the server's V3 plan. The server owns
    /// which rungs are executable for this source; showing the wider Settings
    /// catalog here would let the user request qualities the active plan never
    /// offered.
    static func playbackOptions(
        serverQualities: [PlaybackV3AvailableQuality],
        fallbackVersion: FileVersion?
    ) -> [ApplePlaybackQualityOption] {
        guard !serverQualities.isEmpty else {
            return [auto]
        }
        var seen = Set<String>()
        let planned = serverQualities.compactMap { quality -> ApplePlaybackQualityOption? in
            let id = protocolV3QualityId(quality.label)
            guard id != autoId, seen.insert(id).inserted else { return nil }
            let isOriginal = quality.preservesSource || id == originalId
            let height = quality.height ?? 0
            return ApplePlaybackQualityOption(
                id: id,
                label: playbackLabel(
                    serverDisplayName: quality.displayName,
                    id: id,
                    height: height,
                    isOriginal: isOriginal
                ),
                resolution: isOriginal || height <= 0 ? "" : "\(height)p",
                bitrateKbps: max(0, quality.bitrateKbps),
                isOriginal: isOriginal,
                isAuto: false
            )
        }
        return [auto] + planned
    }

    /// Quality labels in an active V3 plan are server-owned identifiers. Keep
    /// unknown additive rungs instead of coercing them to Auto; only Settings
    /// persistence uses the closed local catalog in `normalizeStoredId`.
    static func protocolV3QualityId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty else { return autoId }
        switch value {
        case "4k", "uhd":
            return ultraHDId
        case "420p":
            return "328p"
        default:
            return value
        }
    }

    /// Resolve an in-player V3 choice without confusing a server-owned rung
    /// with a same-named Settings preset. Compound rung labels are exact plan
    /// identities, and their bitrate comes from that plan rather than Apple's
    /// independently maintained Settings ladder.
    static func protocolV3Selection(
        requestedQualityId: String,
        availableQualities: [PlaybackV3AvailableQuality]
    ) -> ApplePlaybackV3QualitySelection {
        let clientQualityId = protocolV3QualityId(requestedQualityId)
        if clientQualityId == autoId {
            return ApplePlaybackV3QualitySelection(
                clientQualityId: autoId,
                serverPreference: autoId,
                bandwidthCapKbps: nil,
                isServerOwned: true
            )
        }
        if let offered = availableQualities.first(where: {
            protocolV3QualityId($0.label) == clientQualityId
        }) {
            let preservesSource = offered.preservesSource || clientQualityId == originalId
            return ApplePlaybackV3QualitySelection(
                clientQualityId: clientQualityId,
                serverPreference: clientQualityId,
                bandwidthCapKbps: preservesSource ? nil : positiveBitrate(offered.bitrateKbps),
                isServerOwned: true
            )
        }

        let axes = AppleQualityAxes.split(clientQualityId)
        let serverPreference = requestOptions.contains(where: { $0.id == clientQualityId })
            ? axes.resolution
            : clientQualityId
        return ApplePlaybackV3QualitySelection(
            clientQualityId: clientQualityId,
            serverPreference: serverPreference,
            bandwidthCapKbps: axes.bitrateKbps,
            isServerOwned: false
        )
    }

    private static func positiveBitrate(_ bitrateKbps: Int) -> Int? {
        bitrateKbps > 0 ? bitrateKbps : nil
    }

    private static func playbackLabel(
        serverDisplayName: String?,
        id: String,
        height: Int,
        isOriginal: Bool
    ) -> String {
        if isOriginal { return String(localized: "Original") }
        if let serverDisplayName {
            let normalized = serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        switch height {
        case 2_160: return String(localized: "Up to 4K")
        case 1_080: return String(localized: "Up to 1080p HD")
        case 720: return String(localized: "Up to 720p HD")
        case 480: return String(localized: "Up to 480p")
        default:
            return requestOptions.first(where: { $0.id == id })?.label
                ?? (height > 0 ? String(localized: "Up to \(String(height))p", comment: "Quality cap by video height, for example Up to 576p") : id)
        }
    }

    /// The quality the next episode inherits from the current one, if any.
    ///
    /// Original and the capped modes (including a buffering fallback) carry
    /// over. Auto, a Settings tier and this file's own resolution don't: the
    /// next episode resolves its quality afresh from Settings, exactly as
    /// pressing Play on it would, so Auto picks that episode's best version
    /// (4K or 1080p) and plays it directly instead of being pinned to this
    /// episode's resolution and transcoded down to it.
    static func nextEpisodeQualityOverride(activeQualityId: String) -> String? {
        let active = protocolV3QualityId(activeQualityId)
        if active == originalId || PlaybackFallbackMode.matching(active) != nil {
            return active
        }
        return nil
    }

    static func activeProtocolV3QualityId(
        requestedQualityId: String?,
        availableQualities: [PlaybackV3AvailableQuality]
    ) -> String {
        let requested = protocolV3QualityId(requestedQualityId)
        guard requested != autoId else { return autoId }
        if PlaybackFallbackMode.matching(requested) != nil { return requested }
        let requestedResolution = requestOptions.contains(where: { $0.id == requested })
            ? AppleQualityAxes.split(requested).resolution
            : nil
        return availableQualities.contains(where: { quality in
            let offered = protocolV3QualityId(quality.label)
            return offered == requested
                || requestedResolution.map {
                    AppleQualityAxes.split(offered).resolution == $0
                } == true
        }) ? requested : autoId
    }

    static func formatBitrate(kbps: Int) -> String {
        if kbps >= 1000 {
            let mbps = Double(kbps) / 1000.0
            if mbps.rounded(.towardZero) == mbps {
                return String(localized: "\(Int(mbps)) Mbps", comment: "Bitrate in megabits per second")
            }
            let value = String(format: "%.1f", locale: .current, mbps)
            return String(localized: "\(value) Mbps", comment: "Bitrate in megabits per second, with a decimal")
        }
        return String(localized: "\(kbps) kbps", comment: "Bitrate in kilobits per second")
    }

}
