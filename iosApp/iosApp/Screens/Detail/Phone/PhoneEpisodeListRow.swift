#if !os(tvOS)
import SwiftUI

/// One regular-width episode row. The entire row keeps the existing Apple
/// behavior—opening episode detail—while exposing enough title, date,
/// runtime, progress, and overview context to make that choice useful.
struct PhoneEpisodeListRow: View {
    let episode: EpisodeListItem
    let isCurrent: Bool
    let onSelect: () -> Void
    let onPlay: (() -> Void)?

    private let thumbnailWidth: CGFloat = 168
    private var thumbnailHeight: CGFloat { thumbnailWidth * 9 / 16 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 14) {
                    thumbnail
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                PhoneEpisodeFormatting.accessibilityDescription(
                    for: episode,
                    isCurrent: isCurrent
                )
            )

            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.94), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(
                    x: (thumbnailWidth - 38) / 2,
                    y: (thumbnailHeight - 38) / 2
                )
                .accessibilityLabel(
                    "Play Season \(episode.seasonNumber), Episode \(episode.episodeNumber)"
                )
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(
                url: episode.stillUrl ?? "",
                thumbhash: episode.stillThumbhash,
                targetSize: CGSize(width: thumbnailWidth, height: thumbnailHeight),
                contentMode: .fill
            )
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipped()
            .accessibilityHidden(true)

            PhoneEpisodeStatusOverlay(episode: episode, compact: true)
                .padding(7)

        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius)
                .stroke(isCurrent ? Color.white.opacity(0.8) : .clear, lineWidth: 2)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EPISODE \(episode.episodeNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(PhoneEpisodeFormatting.title(for: episode))
                .font(.headline)
                .foregroundStyle(Color.vividOnSurface)
                .lineLimit(1)

            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text(DetailDateFormatting.abbreviatedDate(episode.airDate) ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


}
#endif
