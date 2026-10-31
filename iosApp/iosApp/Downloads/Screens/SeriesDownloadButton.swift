#if os(iOS)
import SwiftUI

/// The download and monitoring button on series, season and episode pages.
/// It opens the series sheet, which can hand over to the monitoring sheet or
/// the single-episode options.
struct SeriesDownloadMenuButton: View {
    enum Style {
        case labeled
    }

    let detail: ItemDetail
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    var episodeVersions: [FileVersion] = []
    var selectedVersionFileId: Int? = nil
    var style: Style = .labeled

    @Environment(\.phoneDetailActionsShareRow) private var sharesActionRow
    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @State private var activeSheet: SheetKind?
    @State private var monitoringPending = false
    @State private var episodeOptionsPending = false
    @State private var showsUnavailable = false
    @State private var errorMessage: String?
    @State private var resolvedPosterPath: String?
    @State private var resolvedPosterThumbhash: String?

    init(
        detail: ItemDetail,
        seasons: [Season],
        selectedSeason: Season?,
        episodes: [EpisodeListItem],
        episodesBySeason: [Int: [EpisodeListItem]],
        episodeVersions: [FileVersion] = [],
        selectedVersionFileId: Int? = nil,
        style: Style = .labeled
    ) {
        self.detail = detail
        self.seasons = seasons
        self.selectedSeason = selectedSeason
        self.episodes = episodes
        self.episodesBySeason = episodesBySeason
        self.episodeVersions = episodeVersions
        self.selectedVersionFileId = selectedVersionFileId
        self.style = style
    }

    private enum SheetKind: Identifiable {
        case series, monitoring, episodeOptions
        var id: Self { self }
    }

    private var manager: DownloadManager { .shared }

    private var metrics: PhoneLabeledActionMetrics {
        PhoneLabeledActionMetrics(sharesRow: sharesActionRow, tvStyle: usesTVStyle)
    }

    var body: some View {
        Button {
            if isUnavailable {
                showsUnavailable = true
            } else {
                activeSheet = .series
            }
        } label: {
            if isUnavailable {
                crossedOutLabel
            } else {
                standardLabel
            }
        }
        .accessibilityLabel(isUnavailable ? Text("Download unavailable") : Text("Download or monitor series"))
        .accessibilityHint(isUnavailable ? Text("Downloads aren't enabled for this account") : Text(verbatim: ""))
        .accessibilityValue(isMonitored ? Text("Monitored") : Text("Not monitored"))
        .modifier(DownloadScreens.UnavailableAlert(isPresented: $showsUnavailable))
        .alert("Download Failed", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
        .sheet(item: $activeSheet, onDismiss: openPendingSheet) { kind in
            sheet(for: kind)
        }
        .task(id: seriesId) { await resolveSeriesPoster() }
    }

    // MARK: Derived

    private var seriesId: String { detail.seriesId ?? detail.contentId }

    private var seriesTitle: String { detail.seriesTitle ?? detail.title }

    private var isSeriesPage: Bool { detail.type == "series" }

    private var offersSingleEpisode: Bool {
        guard detail.type == "episode",
              !manager.hasPendingRequest(contentId: detail.contentId),
              !manager.isWaiting(contentId: detail.contentId) else { return false }
        guard let record = manager.record(forContentId: detail.contentId) else { return true }
        return record.localStatus == .failed
    }

    private var isMonitored: Bool { manager.monitoring(forSeries: seriesId) != nil }

    private var isDownloading: Bool {
        if manager.hasPendingRequest(contentId: seriesId) { return true }
        if manager.waitingDownloads.contains(where: { $0.seriesId == seriesId }) { return true }
        return manager.records.contains { record in
            guard record.seriesId == seriesId || record.contentId == seriesId else { return false }
            switch record.localStatus {
            case .registering, .preparing, .queued, .downloading, .fetchingAssets, .waiting:
                return true
            case .paused, .completed, .failed, .revoked:
                return false
            }
        }
    }

    private var isUnavailable: Bool { manager.downloadsOffForAccount && !isDownloading }

    private var cachedSeries: ItemDetail? {
        ResponseCache.shared.get(CacheKey.itemDetail(seriesId), as: ItemDetail.self)
    }

    private var seriesPosterPath: String? {
        if let resolvedPosterPath { return resolvedPosterPath }
        let fromPage = isSeriesPage ? detail.posterUrl : cachedSeries?.posterUrl
        return fromPage ?? detail.posterUrl
    }

    private var seriesPosterThumbhash: String? {
        if let resolvedPosterThumbhash { return resolvedPosterThumbhash }
        let fromPage = isSeriesPage ? detail.posterThumbhash : cachedSeries?.posterThumbhash
        return fromPage ?? detail.posterThumbhash
    }

    /// The page's episode lists, with the selected season filled in from
    /// the loose episode list when the map doesn't have it yet.
    private var sheetEpisodesBySeason: [Int: [EpisodeListItem]] {
        var map = episodesBySeason
        if let selectedSeason, map[selectedSeason.seasonNumber]?.isEmpty ?? true, !episodes.isEmpty {
            map[selectedSeason.seasonNumber] = episodes
        }
        return map
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: Labels

    private var standardLabel: some View {
        let busy = isDownloading
        let monitored = isMonitored
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(busy || monitored ? 0.18 : 0.10))
                Group {
                    if busy {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                    } else {
                        Image(systemName: monitored ? "arrow.down.circle.fill" : "arrow.down.to.line")
                            .font(.system(size: metrics.iconSize, weight: .regular))
                    }
                }
                .foregroundStyle(Color.vividOnSurface)
                if busy {
                    DownloadScreens.ActivityArc(diameter: metrics.circle - 8, lineWidth: 2.5)
                }
            }
            .frame(width: metrics.circle, height: metrics.circle)
            if metrics.showsCaption {
                captionText(
                    busy ? Text("Downloading") : (monitored ? Text("Monitored") : Text("Download")),
                    opacity: busy || monitored ? 0.92 : 0.6
                )
            }
        }
        .modifier(SlotFrame(metrics: metrics))
    }

    private var crossedOutLabel: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                DownloadScreens.CrossedOutGlyph(size: metrics.iconSize)
            }
            .frame(width: metrics.circle, height: metrics.circle)
            if metrics.showsCaption {
                captionText(Text("Unavailable"), opacity: 0.6)
            }
        }
        .modifier(SlotFrame(metrics: metrics))
    }

    private func captionText(_ text: Text, opacity: Double) -> some View {
        text
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.vividOnSurface.opacity(opacity))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: sharesActionRow, vertical: false)
    }

    /// The slot's width, or the full width without one, at least the row's
    /// height, with the whole rectangle tappable.
    private struct SlotFrame: ViewModifier {
        let metrics: PhoneLabeledActionMetrics

        func body(content: Content) -> some View {
            content
                .frame(width: metrics.slotWidth)
                .frame(maxWidth: metrics.slotWidth == nil ? .infinity : nil, minHeight: metrics.minHeight)
                .contentShape(Rectangle())
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheet(for kind: SheetKind) -> some View {
        switch kind {
        case .series:
            DownloadScreens.SeriesSheet(
                seriesId: seriesId,
                seriesTitle: seriesTitle,
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodesBySeason: sheetEpisodesBySeason,
                posterThumbhash: seriesPosterThumbhash,
                posterPath: seriesPosterPath,
                allowsSeasonDownload: manager.allowsSeasonRequests,
                allowsMonitoring: manager.allowsMonitoring,
                isMonitored: isMonitored,
                episodeTitle: offersSingleEpisode ? detail.title : nil,
                onMonitor: { monitoringPending = true },
                onEpisodeOptions: { episodeOptionsPending = true }
            )
        case .monitoring:
            DownloadScreens.MonitoringSheet(seriesId: seriesId, seriesTitle: seriesTitle, seasons: seasons)
        case .episodeOptions:
            DownloadScreens.OptionsSheet(
                title: detail.title,
                versions: episodeVersions,
                selectedVersionFileId: selectedVersionFileId,
                lastVersionFileId: detail.userData?.lastFileId,
                isEpisode: true,
                onStart: startEpisode
            )
        }
    }

    /// Opens the sheet the series sheet asked for once the last one has
    /// fully closed. Monitoring goes first when both are waiting.
    private func openPendingSheet() {
        if monitoringPending {
            monitoringPending = false
            activeSheet = .monitoring
        } else if episodeOptionsPending {
            episodeOptionsPending = false
            activeSheet = .episodeOptions
        }
    }

    // MARK: Actions

    private func startEpisode(fileId: Int?, quality: String) {
        let posterThumbhash = seriesPosterThumbhash
        let posterPath = seriesPosterPath
        Task { @MainActor in
            do {
                try await manager.downloadEpisode(
                    seriesId: seriesId,
                    episodeId: detail.contentId,
                    displayTitle: detail.title,
                    displaySubtitle: DownloadScreens.episodeTag(
                        season: detail.seasonNumber,
                        episode: detail.episodeNumber,
                        fallback: detail.seriesTitle
                    ),
                    seriesTitle: detail.seriesTitle,
                    posterThumbhash: posterThumbhash,
                    preferredPosterPath: posterPath,
                    fileId: fileId,
                    quality: quality
                )
            } catch DownloadError.registrationAlreadyInFlight {
                // The first request owns the in-progress state.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The series poster for downloads: the page's own on a series page,
    /// else the cached parent series, else a fresh fetch that's cached too.
    private func resolveSeriesPoster() async {
        if isSeriesPage {
            resolvedPosterPath = detail.posterUrl
            resolvedPosterThumbhash = detail.posterThumbhash
            return
        }
        if let cached = cachedSeries {
            resolvedPosterPath = cached.posterUrl
            resolvedPosterThumbhash = cached.posterThumbhash
            return
        }
        let id = seriesId
        guard let series = try? await VividAPI.shared.itemDetail(contentId: id), !Task.isCancelled else { return }
        ResponseCache.shared.set(series, for: CacheKey.itemDetail(id))
        resolvedPosterPath = series.posterUrl
        resolvedPosterThumbhash = series.posterThumbhash
    }
}
#endif
