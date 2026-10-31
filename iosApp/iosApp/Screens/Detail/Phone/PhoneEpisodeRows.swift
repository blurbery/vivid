import SwiftUI

#if !os(tvOS)
/// A season's episodes as rows with a thumbnail, used where the page is
/// wide. Very wide pages use two columns.
struct MobileEpisodeList: View {
    let episodes: [EpisodeListItem]
    let currentEpisodeId: String?
    let onSelect: (EpisodeListItem) -> Void

    @State private var listWidth: CGFloat = 0

    static let rowSpacing: CGFloat = 16

    static func columnCount(width: CGFloat) -> Int {
        width >= 900 ? 2 : 1
    }

    /// The height the season pager reserves for a season of this many
    /// episodes.
    static func estimatedHeight(episodeCount: Int, width: CGFloat, rowHeight: CGFloat) -> CGFloat {
        guard episodeCount > 0 else { return 72 }
        let columns = columnCount(width: width)
        let rows = CGFloat((episodeCount + columns - 1) / columns)
        return rows * rowHeight + (rows - 1) * rowSpacing + 8
    }

    var body: some View {
        let columns = Self.columnCount(width: listWidth)
        let rows = stride(from: 0, to: episodes.count, by: columns).map { start in
            Array(episodes[start..<min(start + columns, episodes.count)])
        }
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<columns, id: \.self) { column in
                        if column < row.count {
                            episodeRow(row[column])
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .hidden()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            listWidth = width
        }
    }

    private func episodeRow(_ episode: EpisodeListItem) -> some View {
        let isCurrent = episode.contentId == currentEpisodeId
        let thumbnailSize = CGSize(width: 168, height: 168 * 9 / 16)
        let shape = RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius)
        return Button {
            onSelect(episode)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottom) {
                    MobileEpisodeStill(episode: episode, size: thumbnailSize, symbolSize: 18)
                        .accessibilityHidden(true)
                    MobileEpisodeStatus(episode: episode, isCompact: true)
                        .padding(7)
                }
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(shape)
                .overlay(shape.stroke(isCurrent ? Color.white.opacity(0.80) : .clear, lineWidth: 2))

                VStack(alignment: .leading, spacing: 4) {
                    Text("EPISODE \(String(episode.episodeNumber))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: MobileEpisodeText.title(episode))
                        .font(.headline)
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(verbatim: overview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(verbatim: DetailDateFormatting.abbreviatedDate(episode.airDate) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: MobileEpisodeText.spokenDescription(episode, isCurrent: isCurrent)))
        .modifier(MobileEpisodeWatchedMenu(episode: episode))
    }
}

/// Three grey rows while a season's episodes load.
struct MobileEpisodeListSkeleton: View {
    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { index in
                HStack(alignment: .center, spacing: 14) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.09 + 0.01 * Double(index)))
                        .frame(width: 136, height: 76)
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 150, height: 11)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .frame(maxWidth: .infinity)
                            .frame(height: 9)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(maxWidth: 240)
                            .frame(height: 9)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
