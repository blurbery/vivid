import SwiftUI
#if !os(tvOS)

/// "Details" key/value list rendered below the hero. Mirrors
/// `TVDetailFactsSection` — same data sources (crew, studios, networks,
/// dates) — but laid out as a phone-friendly inset list with thin
/// dividers and tight rows.
struct PhoneDetailFactsSection: View {
    let detail: ItemDetail

    private let maxCreditNames = 3

    var body: some View {
        let facts = assembleFacts()
        if !facts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.label) { index, fact in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 42)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fact.label.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(fact.value)
                                .font(.system(size: 14))
                                .lineLimit(3)
                        }
                        .frame(width: 170, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
    }

    private struct Fact {
        let label: String
        let value: String
    }

    private func assembleFacts() -> [Fact] {
        var facts: [Fact] = []

        if let directors = creditNames(forJobs: ["Director"]), !directors.isEmpty {
            facts.append(Fact(label: "Director", value: directors))
        }
        if let writers = creditNames(forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(Fact(label: writerLabel, value: writers))
        }
        if let studios = detail.studios, !studios.isEmpty {
            facts.append(Fact(label: "Studio", value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(Fact(label: "Network", value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(Fact(label: "Country", value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(Fact(label: "Aired", value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: "Released", value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(Fact(label: "First Aired", value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(Fact(label: "Last Aired", value: lastAired))
        }
        return facts
    }

    private var writerLabel: String {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? "Writer" : "Written by"
    }

    private func creditNames(forJobs jobs: [String]) -> String? {
        guard let crew = detail.crew else { return nil }
        let lowered = jobs.map { $0.lowercased() }
        let names = crew
            .filter { member in
                guard let job = member.job?.lowercased() else { return false }
                return lowered.contains(job)
            }
            .map(\.name)
        if names.isEmpty { return nil }
        let trimmed = Array(Set(names)).sorted()
        let joined = trimmed.prefix(maxCreditNames).joined(separator: ", ")
        return trimmed.count > maxCreditNames ? "\(joined), …" : joined
    }
}
#endif

struct DetailMediaSection: View {
    let version: FileVersion?

    private var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private struct Field {
        let label: String
        let value: String
    }

    var body: some View {
        if let version {
            VStack(alignment: .leading, spacing: 14) {
                panel(title: "Video & File", icon: "video.fill") {
                    fields(videoFields(version), maximumColumns: 5)
                    if let name = clean(version.fileName) {
                        Divider().overlay(.white.opacity(0.12))
                        Text(name)
                            .font(.system(size: isTV ? 18 : 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                    }
                }
                let tracks = version.audioTracks ?? []
                if !tracks.isEmpty {
                    panel(title: "Audio", icon: "music.note") {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            if index > 0 { Divider().overlay(.white.opacity(0.12)) }
                            Text(clean(track.title) ?? "Track \(index + 1)")
                                .font(.system(size: isTV ? 22 : 14, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            fields(audioFields(track))
                        }
                    }
                } else if let codec = clean(version.codecAudio) {
                    panel(title: "Audio", icon: "music.note") {
                        fields([Field(label: "Codec", value: codec.uppercased())])
                    }
                }
            }
        } else {
            Text("Media information is unavailable for this file.")
                .font(.system(size: isTV ? 22 : 14))
                .foregroundStyle(.secondary)
        }
    }

    private func panel<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.system(size: isTV ? 26 : 16, weight: .semibold))
            content()
        }
        .padding(isTV ? 28 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        #if os(tvOS)
        .focusable()
        #endif
    }

    private func fields(_ values: [Field], maximumColumns: Int = 4) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .topLeading), count: min(maximumColumns, values.count)), alignment: .leading, spacing: isTV ? 24 : 18) {
            ForEach(values.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text(values[index].label.uppercased())
                        .font(.system(size: isTV ? 16 : 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                    Text(values[index].value)
                        .font(.system(size: isTV ? 22 : 13))
                        .fixedSize(horizontal: false, vertical: true)
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func videoFields(_ file: FileVersion) -> [Field] {
        let video = file.videoTracks?.first
        var result: [Field] = []
        func add(_ label: String, _ value: String?) {
            if let value = clean(value) { result.append(Field(label: label, value: value)) }
        }
        add("Container", file.container?.uppercased())
        if let size = file.fileSize, size > 0 {
            add("File size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let duration = file.duration, duration.isFinite, duration > 0 {
            add("Duration", PlayerTimeFormatter.formatHMS(duration))
        }
        add("Codec", (video?.codec ?? file.codecVideo)?.uppercased())
        if let width = video?.width, let height = video?.height, width > 0, height > 0 {
            add("Resolution", "\(width) × \(height)")
        } else { add("Resolution", file.resolution) }
        add("Profile", video?.profile)
        if let level = video?.level, level > 0 { add("Level", String(level)) }
        if let rate = clean(video?.frameRate) { add("Frame rate", "\(rate) fps") }
        add("Video bitrate", bitrate(video?.bitrate, useMbps: true))
        add("Overall bitrate", bitrate(file.bitrate, useMbps: true))
        add("Video range", video?.videoRange ?? file.hdr.map { $0 ? "HDR" : "SDR" })
        add("Dolby Vision", video?.dolbyVision)
        if let depth = video?.bitDepth, depth > 0 { add("Bit depth", "\(depth) bit") }
        add("Color range", video?.colorRange)
        add("Color primaries", video?.colorPrimaries)
        add("Color space", video?.colorSpace)
        add("Color transfer", video?.colorTransfer)
        return result
    }

    private func audioFields(_ track: AudioTrack) -> [Field] {
        var result: [Field] = []
        func add(_ label: String, _ value: String?) {
            if let value = clean(value) { result.append(Field(label: label, value: value)) }
        }
        if let language = clean(track.language) {
            add("Language", Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        add("Codec", track.codec?.uppercased())
        add("Channel layout", track.channelLayout)
        if let channels = track.channels, channels > 0 { add("Channels", String(channels)) }
        if let rate = track.sampleRate, rate > 0 { add("Sample rate", "\(rate) Hz") }
        add("Bitrate", bitrate(track.bitrate))
        if let isDefault = track.isDefault { add("Default", isDefault ? "Yes" : "No") }
        return result
    }

    private func bitrate(_ value: Int?, useMbps: Bool = false) -> String? {
        guard let value, value > 0 else { return nil }
        let kbps = MediaServerProvider.active == .emby ? Double(value) / 1_000 : Double(value)
        return useMbps || kbps >= 1_000
            ? String(format: "%.2f Mbps", kbps / 1_000)
            : String(format: "%.0f kbps", kbps)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
