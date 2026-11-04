#if !os(tvOS)
import SwiftUI

/// A version as the season, series and Choose Episodes pages list it: named
/// like a movie's version, with how many episodes have it and roughly how
/// much they'd download.
struct SeriesDownloadVersion: Hashable {
    let version: DownloadVersionPreference
    let title: String
    let episodes: Int
    let totalEpisodes: Int
    let bytes: Int64

    /// "All 8 episodes · about 85.69 GB" or "6 of 8 episodes".
    var detail: String {
        let count = episodes == totalEpisodes
            ? String(localized: "All \(totalEpisodes) episodes")
            : String(localized: "\(episodes) of \(totalEpisodes) episodes")
        guard bytes > 0 else { return count }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "\(count) · about \(size)")
    }

    /// One entry per version among the episodes' files, highest first.
    /// Episodes without files don't count. The codec shows when every
    /// matching file names the same one. Episode lists don't say which HDR
    /// format a file uses, so it reads "HDR".
    static func versions(in episodes: [EpisodeListItem]) -> [SeriesDownloadVersion] {
        let fileLists = episodes.compactMap(\.files).filter { !$0.isEmpty }
        return DownloadVersionPreference.options(for: fileLists.flatMap { $0 }).map { version in
            let matched = fileLists.compactMap { version.file(in: $0) }
            return SeriesDownloadVersion(
                version: version,
                title: title(of: version, codec: sharedCodec(of: matched)),
                episodes: matched.count,
                totalEpisodes: fileLists.count,
                bytes: matched.compactMap(\.fileSize).reduce(0, +)
            )
        }
    }

    /// "2160p · HEVC · HDR", "1080p" or "SD".
    private static func title(of version: DownloadVersionPreference, codec: String?) -> String {
        let resolution = version.height == 480 ? "SD" : "\(version.height)p"
        return [resolution, codec, version.hdr == true ? "HDR" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The codec every file names, or nil when one doesn't say or they differ.
    private static func sharedCodec(of files: [EpisodeFile]) -> String? {
        let codecs = files.map { DetailPlaybackFormatting.normalizedVideoCodec($0.codecVideo) }
        guard let first = codecs.first, codecs.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The Choose Version row: the pick, or Auto with what's on offer.
    static func rowDetail(_ versions: [SeriesDownloadVersion], chosen: DownloadVersionPreference?) -> String {
        if let chosen, let match = versions.first(where: { $0.version == chosen }) {
            return "\(match.title) · \(match.detail)"
        }
        let names = versions.prefix(3).map(\.title).joined(separator: ", ")
        return names.isEmpty ? String(localized: "Auto") : String(localized: "Auto · \(names)")
    }
}

/// Choose Version for a season, the whole series or Choose Episodes. Each
/// episode downloads its own file in the chosen version.
struct SeriesDownloadVersionPage: View {
    let versions: [SeriesDownloadVersion]
    /// Emby lists one file per episode, so the page reads the rest first.
    let isChecking: Bool
    let isEmbyConversion: Bool
    @Binding var version: DownloadVersionPreference?
    var onAppear: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                DownloadChoiceRow(
                    title: String(localized: "Auto"),
                    detail: String(localized: "Each episode uses the server's usual file"),
                    isSelected: version == nil
                ) {
                    choose(nil)
                }
                ForEach(versions, id: \.version) { option in
                    DownloadChoiceRow(
                        title: option.title,
                        detail: option.detail,
                        isSelected: version == option.version
                    ) {
                        choose(option.version)
                    }
                }
                if isChecking {
                    checkingRow
                }
            } header: {
                Text("Version")
            } footer: {
                Text(isEmbyConversion
                     ? "Emby chooses the source version when preparing a smaller download."
                     : "Each episode downloads its own file in this version. Episodes without one use the server's usual file.")
            }
            .disabled(isEmbyConversion)
        }
        .navigationTitle("Choose Version")
        .navigationBarTitleDisplayMode(.inline)
        .vividScrollContentBackgroundHidden()
        .background(Color.clear)
        .task { await onAppear() }
    }

    private var checkingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking each episode's files…")
                .font(.vividCaption)
                .foregroundColor(.vividSecondaryText)
        }
    }

    private func choose(_ choice: DownloadVersionPreference?) {
        version = choice
        dismiss()
    }
}
#endif
