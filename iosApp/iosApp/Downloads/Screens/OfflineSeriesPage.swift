#if os(iOS)
import SwiftUI

/// One downloaded series, season by season, playable without a server.
struct OfflineSeriesBrowseView: View {
    let seriesId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var chosenSeason: Int?

    init(seriesId: String) {
        self.seriesId = seriesId
    }

    private var manager: DownloadManager { .shared }

    var body: some View {
        let group = manager.savedSeries.first { $0.seriesId == seriesId }
        Group {
            if let group {
                content(group)
            } else {
                EmptyStateView(icon: "tv", title: "No Downloads", subtitle: "This series has no downloaded episodes.")
            }
        }
        .vividPageBackground()
        .navigationTitle(Text(verbatim: group?.displayTitle ?? DownloadScreens.seriesLabel))
        .navigationBarTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        .toolbar {
            if let group {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Delete All Episodes", systemImage: "trash", role: .destructive) {
                            manager.remove(recordIds: group.everyRecord.map(\.id))
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func content(_ group: DownloadedSeries) -> some View {
        let season = currentSeason(in: group)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero(group, season: season)
                if group.seasonGroups.count > 1 {
                    seasonChips(group, current: season)
                }
                if let season {
                    episodesHeader(season)
                    ForEach(season.episodes) { record in
                        DownloadScreens.EpisodeRow(
                            record: record,
                            isWatched: manager.isFinishedWatching(record),
                            onPlay: { DownloadScreens.play(record, router: router) },
                            onDelete: { manager.remove(recordId: record.id) }
                        )
                    }
                }
                Color.clear
                    .frame(height: 30)
            }
        }
    }

    /// The chosen season while the series still has it, else the first.
    private func currentSeason(in group: DownloadedSeries) -> DownloadedSeason? {
        if let chosenSeason, let match = group.seasonGroups.first(where: { $0.seasonKey == chosenSeason }) {
            return match
        }
        return group.seasonGroups.first
    }

    // MARK: Hero

    private func hero(_ group: DownloadedSeries, season: DownloadedSeason?) -> some View {
        let target = playTarget(in: season)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .bottom, spacing: 14) {
                DownloadScreens.PosterTile(
                    thumbhash: group.artworkHash,
                    file: DownloadScreens.firstPosterFile(in: group.everyRecord),
                    width: 72,
                    cornerRadius: 10
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(verbatim: eyebrow(group))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.vividSecondaryText)
                        if group.hasMonitoring {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.vividOnSurface)
                        }
                    }
                    Text(verbatim: group.displayTitle)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                }
            }
            DownloadScreens.AvailabilityChip(text: String(
                localized: "Downloaded · \(group.episodeTotal) episodes · \(DownloadScreens.byteText(group.storedBytes))"
            ))
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: playTitle(for: target),
                action: {
                    if let target { DownloadScreens.play(target, router: router) }
                },
                fullWidth: true
            )
        }
        .padding(18)
        .downloadGlassCard(cornerRadius: 20)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func eyebrow(_ group: DownloadedSeries) -> String {
        guard group.seasonTotal > 1 else { return DownloadScreens.seriesLabel }
        return String(
            localized: "Series · \(group.seasonTotal) seasons",
            comment: "Eyebrow above a downloaded series' title, e.g. Series · 3 seasons"
        )
    }

    /// The first unwatched episode of the season, or its first episode when
    /// all are watched.
    private func playTarget(in season: DownloadedSeason?) -> DownloadRecord? {
        guard let season else { return nil }
        return season.episodes.first { !manager.isFinishedWatching($0) } ?? season.episodes.first
    }

    /// "Resume S1·E4" past 30 seconds in, else "Play S1·E4".
    private func playTitle(for target: DownloadRecord?) -> String {
        guard let target else { return String(localized: "Play") }
        let position = manager.savedProgress(for: target.leafMediaItemId)?.position ?? 0
        let resumes = position > 30
        guard let episode = target.episodeNumber else {
            return resumes ? String(localized: "Resume") : String(localized: "Play")
        }
        let episodeText = String(episode)
        if let season = target.seasonNumber, season > 0 {
            let seasonText = String(season)
            return resumes
                ? String(localized: "Resume S\(seasonText)·E\(episodeText)", comment: "Button that resumes a season and episode, e.g. Resume S1·E4")
                : String(localized: "Play S\(seasonText)·E\(episodeText)", comment: "Button that plays a season and episode, e.g. Play S1·E4")
        }
        return resumes
            ? String(localized: "Resume E\(episodeText)", comment: "Button that resumes an episode, e.g. Resume E4")
            : String(localized: "Play E\(episodeText)", comment: "Button that plays an episode, e.g. Play E4")
    }

    // MARK: Seasons and episodes

    private func seasonChips(_ group: DownloadedSeries, current: DownloadedSeason?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(group.seasonGroups) { season in
                    let isCurrent = season.seasonKey == current?.seasonKey
                    Button {
                        chosenSeason = season.seasonKey
                    } label: {
                        Text(verbatim: DownloadScreens.seasonName(season))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isCurrent ? Color.vividOnSurface : Color.vividSecondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(isCurrent ? Color.vividChromeSelectedFill : Color.vividChromeRestingFill))
                            .overlay(Capsule().stroke(
                                isCurrent ? Color.vividChromeSelectedBorder : Color.vividChromeRestingBorder,
                                lineWidth: 1
                            ))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 14)
    }

    private func episodesHeader(_ season: DownloadedSeason) -> some View {
        HStack {
            Text("Episodes")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.vividOnSurface)
            Spacer()
            Text("\(season.episodeTotal) on this device · \(DownloadScreens.byteText(season.storedBytes))")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.vividOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}
#endif
