import SwiftUI

/// Media Information: a Video & File panel and an Audio panel for one file,
/// on iPhone, iPad and Apple TV.
struct DetailMediaSection: View {
    let version: FileVersion?

    init(version: FileVersion?) {
        self.version = version
    }

    var body: some View {
        if let version {
            VStack(alignment: .leading, spacing: 14) {
                DetailMediaPanel(title: "Video & File", icon: "video.fill") {
                    DetailMediaFieldGrid(fields: DetailMediaFacts.videoFields(version), maxColumns: 5)
                    if let name = DetailMediaFacts.trimmed(version.fileName) {
                        DetailMediaDivider()
                        Text(verbatim: name)
                            .font(.system(size: DetailMediaPanelSizes.fileName))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mediaValueSelection()
                    }
                }
                if let tracks = version.audioTracks, !tracks.isEmpty {
                    DetailMediaPanel(title: "Audio", icon: "music.note") {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            if index > 0 {
                                DetailMediaDivider()
                            }
                            Text(verbatim: DetailMediaFacts.trackTitle(track, position: index + 1))
                                .font(.system(size: DetailMediaPanelSizes.trackTitle, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            DetailMediaFieldGrid(fields: DetailMediaFacts.audioFields(track), maxColumns: 4)
                        }
                    }
                } else if let codec = DetailMediaFacts.trimmed(version.codecAudio) {
                    DetailMediaPanel(title: "Audio", icon: "music.note") {
                        DetailMediaFieldGrid(
                            fields: [DetailMediaField(id: "Codec", label: String(localized: "Codec"), value: codec.uppercased())],
                            maxColumns: 4
                        )
                    }
                }
            }
        } else {
            Text("Media information is unavailable for this file.")
                .font(.system(size: DetailMediaPanelSizes.unavailable))
                .foregroundStyle(.secondary)
        }
    }
}

private enum DetailMediaPanelSizes {
    #if os(tvOS)
    static let title: CGFloat = 26
    static let padding: CGFloat = 28
    static let rowSpacing: CGFloat = 24
    static let label: CGFloat = 16
    static let value: CGFloat = 22
    static let fileName: CGFloat = 18
    static let trackTitle: CGFloat = 22
    static let unavailable: CGFloat = 22
    #else
    static let title: CGFloat = 16
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 18
    static let label: CGFloat = 10
    static let value: CGFloat = 13
    static let fileName: CGFloat = 12
    static let trackTitle: CGFloat = 14
    static let unavailable: CGFloat = 14
    #endif
}

private struct DetailMediaPanel<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.system(size: DetailMediaPanelSizes.title, weight: .semibold))
            content()
        }
        .padding(DetailMediaPanelSizes.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
        #if os(tvOS)
        .focusable()
        #endif
    }
}

private struct DetailMediaDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.12))
    }
}

private struct DetailMediaField: Identifiable {
    /// The English label, so identity is the same in every language.
    let id: String
    let label: String
    let value: String
}

private struct DetailMediaFieldGrid: View {
    let fields: [DetailMediaField]
    let maxColumns: Int

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .topLeading),
            count: min(maxColumns, fields.count)
        )
        LazyVGrid(columns: columns, alignment: .leading, spacing: DetailMediaPanelSizes.rowSpacing) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: field.label.uppercased())
                        .font(.system(size: DetailMediaPanelSizes.label, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                    Text(verbatim: field.value)
                        .font(.system(size: DetailMediaPanelSizes.value))
                        .fixedSize(horizontal: false, vertical: true)
                        .mediaValueSelection()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private extension View {
    /// Values and file names can be copied on iPhone and iPad.
    func mediaValueSelection() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

/// The fields each panel shows, in order. A field appears only when its
/// value has something in it once trimmed.
private enum DetailMediaFacts {
    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func trackTitle(_ track: AudioTrack, position: Int) -> String {
        trimmed(track.title) ?? String(localized: "Track \(position)")
    }

    static func videoFields(_ version: FileVersion) -> [DetailMediaField] {
        let track = version.videoTracks?.first
        var fields: [DetailMediaField] = []
        func add(_ id: String, _ label: String, _ value: String?) {
            guard let value = trimmed(value) else { return }
            fields.append(DetailMediaField(id: id, label: label, value: value))
        }

        add("Container", String(localized: "Container"), version.container?.uppercased())
        if let size = version.fileSize, size > 0 {
            add("File size", String(localized: "File size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let duration = version.duration, duration.isFinite, duration > 0 {
            add("Duration", String(localized: "Duration"), PlayerTimeFormatter.formatHMS(duration))
        }
        add("Codec", String(localized: "Codec"), (track?.codec ?? version.codecVideo)?.uppercased())
        if let width = track?.width, let height = track?.height, width > 0, height > 0 {
            add("Resolution", String(localized: "Resolution"), "\(width) × \(height)")
        } else {
            add("Resolution", String(localized: "Resolution"), version.resolution)
        }
        add(
            "Profile",
            String(
                localized: "mediaInfo.videoProfile",
                defaultValue: "Profile",
                comment: "Video codec profile, e.g. Main 10, in the media information panel"
            ),
            track?.profile
        )
        if let level = track?.level, level > 0 {
            add("Level", String(localized: "Level"), String(level))
        }
        if let rate = trimmed(track?.frameRate) {
            add("Frame rate", String(localized: "Frame rate"), String(localized: "\(rate) fps"))
        }
        add("Video bitrate", String(localized: "Video bitrate"), bitrate(track?.bitrate, alwaysMbps: true))
        add("Overall bitrate", String(localized: "Overall bitrate"), bitrate(version.bitrate, alwaysMbps: true))
        let range = PlayerStreamBadges.dynamicRange(version)
            ?? track?.videoRange
            ?? version.hdr.map { $0 ? "HDR" : "SDR" }
        add("Video range", String(localized: "Video range"), range)
        add("Dolby Vision", String(localized: "Dolby Vision"), track?.dolbyVision)
        if let depth = track?.bitDepth, depth > 0 {
            add("Bit depth", String(localized: "Bit depth"), String(localized: "\(depth) bit"))
        }
        add("Color range", String(localized: "Color range"), track?.colorRange)
        add("Color primaries", String(localized: "Color primaries"), track?.colorPrimaries)
        add("Color space", String(localized: "Color space"), track?.colorSpace)
        add("Color transfer", String(localized: "Color transfer"), track?.colorTransfer)
        return fields
    }

    static func audioFields(_ track: AudioTrack) -> [DetailMediaField] {
        var fields: [DetailMediaField] = []
        func add(_ id: String, _ label: String, _ value: String?) {
            guard let value = trimmed(value) else { return }
            fields.append(DetailMediaField(id: id, label: label, value: value))
        }

        if let code = trimmed(track.language) {
            add("Language", String(localized: "Language"), Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        add("Codec", String(localized: "Codec"), track.codec?.uppercased())
        add("Channel layout", String(localized: "Channel layout"), track.channelLayout)
        if let channels = track.channels, channels > 0 {
            add("Channels", String(localized: "Channels"), String(channels))
        }
        if let rate = track.sampleRate, rate > 0 {
            add("Sample rate", String(localized: "Sample rate"), "\(rate) Hz")
        }
        add("Bitrate", String(localized: "Bitrate"), bitrate(track.bitrate, alwaysMbps: false))
        if let isDefault = track.isDefault {
            add("Default", String(localized: "Default"), isDefault ? String(localized: "Yes") : String(localized: "No"))
        }
        return fields
    }

    /// Emby and Jellyfin report bits per second, Silo kilobits.
    static func bitrate(_ raw: Int?, alwaysMbps: Bool) -> String? {
        guard let raw, raw > 0 else { return nil }
        let kbps = MediaServerProvider.active.usesNativeUser ? Double(raw) / 1000 : Double(raw)
        if alwaysMbps || kbps >= 1000 {
            let value = (kbps / 1000).formatted(.number.precision(.fractionLength(2)).grouping(.never))
            return String(localized: "\(value) Mbps")
        }
        let value = kbps.formatted(.number.precision(.fractionLength(0)).grouping(.never))
        return String(localized: "\(value) kbps")
    }
}
