#if !os(tvOS)
import SwiftUI

/// Series-level download + monitoring control for the series/season detail
/// action row. A circle menu offering whole-season / whole-series download
/// and a series-monitoring subscription editor. Reads
/// `DownloadManager.shared` directly so it reflects live state.
struct SeriesDownloadMenuButton: View {
    let detail: ItemDetail
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    /// The page's episode files, so one episode can be downloaded with the
    /// same version and quality choices as a movie.
    var episodeVersions: [FileVersion] = []
    var selectedVersionFileId: Int? = nil

    private var manager: DownloadManager { DownloadManager.shared }
    @State private var activeSheet: SeriesDownloadSheet?
    @State private var pendingMonitorSheet = false
    @State private var pendingEpisodeOptions = false
    @State private var episodeDownloadError: String?
    @State private var resolvedSeriesPosterPath: String?
    @State private var resolvedSeriesPosterThumbhash: String?
    @State private var showUnavailable = false

    /// Presentation of the trigger. `labeled` matches the detail page's named
    /// action row; `circle` is the original chrome, still used elsewhere.
    enum Style {
        case circle
        case labeled
    }

    var style: Style = .circle

    private var seriesId: String { detail.seriesId ?? detail.contentId }
    /// Only an episode page offers the single-episode options, and only while
    /// that episode isn't already queued or downloaded. A failed download can
    /// be retried with new options.
    private var canChooseEpisodeOptions: Bool {
        guard detail.type == "episode", !manager.isRegistering(contentId: detail.contentId) else { return false }
        guard let record = manager.record(forContentId: detail.contentId) else { return true }
        return record.localStatus == .failed
    }
    private var isMonitored: Bool { manager.subscription(forSeriesId: seriesId) != nil }
    private var isDownloading: Bool {
        manager.isRegistering(contentId: seriesId)
            || manager.waitingDownloads.contains { $0.seriesId == seriesId }
            || manager.records.contains { record in
                guard record.seriesId == seriesId || record.contentId == seriesId else { return false }
                switch record.localStatus {
                case .registering, .preparing, .queued, .downloading, .fetchingAssets, .waiting:
                    return true
                case .paused, .completed, .failed, .revoked:
                    return false
                }
            }
    }
    private var seriesPosterPath: String? {
        resolvedSeriesPosterPath
            ?? (detail.type == "series" ? detail.posterUrl : cachedParentSeries?.posterUrl)
            ?? detail.posterUrl
    }
    private var seriesPosterThumbhash: String? {
        resolvedSeriesPosterThumbhash
            ?? (detail.type == "series" ? detail.posterThumbhash : cachedParentSeries?.posterThumbhash)
            ?? detail.posterThumbhash
    }
    private var cachedParentSeries: ItemDetail? {
        ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
    }
    private var cachedEpisodesBySeason: [Int: [EpisodeListItem]] {
        var cached = episodesBySeason
        if let seasonNumber = selectedSeason?.seasonNumber,
           cached[seasonNumber]?.isEmpty != false,
           !episodes.isEmpty {
            cached[seasonNumber] = episodes
        }
        return cached
    }

    private var circleLabel: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isMonitored || isDownloading ? 0.18 : 0.10))
                .overlay(Circle().stroke(Color.white.opacity(isMonitored || isDownloading ? 0.55 : 0.25), lineWidth: 1))
            Image(systemName: isDownloading ? "arrow.down" : (isMonitored ? "arrow.down.circle.fill" : "arrow.down.circle"))
                .font(.system(size: isDownloading ? 12 : 16, weight: .semibold))
                .foregroundColor(.white)
            if isDownloading {
                DownloadActivityRing(diameter: 36, lineWidth: 2.5)
            }
        }
        .frame(width: 44, height: 44)
    }

    /// Filled, borderless circle over a caption, matching
    /// `PhoneLabeledAction`'s metrics.
    private var labeledLabel: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(isMonitored || isDownloading ? 0.18 : 0.10))
                Image(systemName: isDownloading ? "arrow.down" : (isMonitored ? "arrow.down.circle.fill" : "arrow.down.to.line"))
                    .font(.system(size: isDownloading ? 11 : 19, weight: isDownloading ? .bold : .regular))
                    .foregroundColor(Color.vividOnSurface)
                if isDownloading {
                    DownloadActivityRing(diameter: 34, lineWidth: 2.5)
                }
            }
            .frame(width: 42, height: 42)
            Text(isDownloading ? "Downloading" : (isMonitored ? "Monitored" : "Download"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.vividOnSurface.opacity(isMonitored || isDownloading ? 0.92 : 0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }

    /// Downloads are off for this account and nothing is in flight, so the
    /// control shows crossed out instead of disappearing.
    private var showsUnavailable: Bool { manager.downloadsDisallowed && !isDownloading }

    @ViewBuilder
    private var unavailableLabel: some View {
        switch style {
        case .circle:
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                DownloadUnavailableGlyph(size: 16)
            }
            .frame(width: 44, height: 44)
        case .labeled:
            VStack(spacing: 6) {
                DownloadUnavailableGlyph(size: 19)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                Text("Unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.vividOnSurface.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
    }

    var body: some View {
        Button {
            if showsUnavailable { showUnavailable = true } else { activeSheet = .downloadOptions }
        } label: {
            if showsUnavailable {
                unavailableLabel
            } else {
                switch style {
                case .circle: circleLabel
                case .labeled: labeledLabel
                }
            }
        }
        .downloadsUnavailableAlert(isPresented: $showUnavailable)
        .accessibilityLabel(showsUnavailable ? "Download unavailable" : "Download or monitor series")
        .accessibilityHint(showsUnavailable ? "Downloads aren't enabled for this account" : "")
        .accessibilityValue(isMonitored ? "Monitored" : "Not monitored")
        // Chaining sheets from `onDismiss` waits out the real dismiss
        // animation instead of guessing a delay — a fixed sleep silently
        // fails to present when teardown runs long (slow device,
        // accessibility animations, low power).
        .sheet(item: $activeSheet, onDismiss: {
            if pendingMonitorSheet {
                pendingMonitorSheet = false
                activeSheet = .monitor
            } else if pendingEpisodeOptions {
                pendingEpisodeOptions = false
                activeSheet = .episodeOptions
            }
        }) { sheet in
            switch sheet {
            case .downloadOptions:
                SeriesDownloadOptionsSheet(
                    seriesId: seriesId,
                    seriesTitle: detail.seriesTitle ?? detail.title,
                    seasons: seasons,
                    selectedSeason: selectedSeason,
                    cachedEpisodesBySeason: cachedEpisodesBySeason,
                    posterThumbhash: seriesPosterThumbhash,
                    preferredPosterPath: seriesPosterPath,
                    canDownloadSeason: manager.canDownloadSeason,
                    canMonitorSeries: manager.canMonitorSeries,
                    isMonitored: isMonitored,
                    episodeTitle: canChooseEpisodeOptions ? detail.title : nil,
                    onMonitor: { pendingMonitorSheet = true },
                    onEpisodeOptions: { pendingEpisodeOptions = true }
                )
            case .monitor:
                SeriesMonitorSheet(seriesId: seriesId, seriesTitle: detail.seriesTitle ?? detail.title, seasons: seasons)
            case .episodeOptions:
                DownloadOptionsSheet(
                    title: detail.title,
                    versions: episodeVersions,
                    selectedVersionFileId: selectedVersionFileId,
                    lastVersionFileId: detail.userData?.lastFileId,
                    isEpisode: true,
                    onStart: startEpisodeDownload
                )
            }
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { episodeDownloadError != nil },
                set: { if !$0 { episodeDownloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(episodeDownloadError ?? "")
        }
        .task(id: seriesId) {
            if detail.type == "series" {
                resolvedSeriesPosterPath = detail.posterUrl
                resolvedSeriesPosterThumbhash = detail.posterThumbhash
                return
            }
            if let cachedParentSeries {
                resolvedSeriesPosterPath = cachedParentSeries.posterUrl
                resolvedSeriesPosterThumbhash = cachedParentSeries.posterThumbhash
                return
            }
            guard let series = try? await VividAPI.shared.itemDetail(contentId: seriesId),
                  !Task.isCancelled else { return }
            ResponseCache.shared.set(series, for: CacheKey.itemDetail(seriesId))
            resolvedSeriesPosterPath = series.posterUrl
            resolvedSeriesPosterThumbhash = series.posterThumbhash
        }
    }

    private func startEpisodeDownload(_ options: DownloadRequestOptions) {
        Task {
            do {
                try await manager.downloadEpisode(
                    seriesId: seriesId,
                    episodeId: detail.contentId,
                    displayTitle: detail.title,
                    displaySubtitle: DownloadActionButton.episodeSubtitle(
                        seasonNumber: detail.seasonNumber,
                        episodeNumber: detail.episodeNumber,
                        fallback: detail.seriesTitle
                    ),
                    seriesTitle: detail.seriesTitle,
                    posterThumbhash: seriesPosterThumbhash,
                    preferredPosterPath: seriesPosterPath,
                    fileId: options.fileId,
                    quality: options.quality
                )
            } catch DownloadError.registrationAlreadyInFlight {
                // The first request owns the Preparing state.
            } catch {
                episodeDownloadError = error.localizedDescription
            }
        }
    }
}

/// Inline quality choice for every download sheet: Original, or a smaller
/// transcode of the chosen version, listing what the server offers for this
/// account. A 4K version only offers 4K transcodes; a smaller version offers
/// the whole ladder below it.
struct DownloadQualityPicker: View {
    @Binding var quality: String
    /// The chosen version's resolution class; nil (Auto) offers everything.
    var versionHeight: Int? = nil
    private var manager: DownloadManager { DownloadManager.shared }

    static func formats(versionHeight: Int?) -> [DownloadFormat] {
        let manager = DownloadManager.shared
        let available = manager.availableFormats
        return DownloadVersionPreference.formats(
            available.isEmpty ? [.original] : available,
            versionHeight: versionHeight,
            maxHeight: manager.maxHeight(for:)
        )
    }

    private var formats: [DownloadFormat] { Self.formats(versionHeight: versionHeight) }

    var body: some View {
        Picker(selection: $quality) {
            ForEach(formats, id: \.self) { format in
                Text(manager.qualityLabel(format)).tag(format.rawValue)
            }
        } label: {
            Label("Quality", systemImage: "slider.horizontal.3")
        }
        .pickerStyle(.menu)
        .onAppear(perform: clamp)
        .onChange(of: manager.availableFormats) { _, _ in clamp() }
        .onChange(of: versionHeight) { _, _ in clamp() }
    }

    /// The chosen quality's size, for the line under the menu (menus show
    /// one line per choice).
    static func sizeNote(_ quality: String) -> String? {
        DownloadFormat(rawValue: quality).flatMap(DownloadManager.sizePerHour).map { "\($0) of video." }
    }

    /// The line under Choose Version and Quality.
    static func footer(quality: String, versionHeight: Int?, scope: String? = nil) -> String {
        [scope,
         sizeNote(quality),
         "Lower bitrates make a smaller copy of the chosen version. The server prepares it first, which can take longer. Sizes are estimates.",
         versionHeight.map { $0 >= 2160 } == true ? "A 4K version only makes 4K copies. Choose a smaller version for a smaller resolution." : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// A smaller quality the new version can't make moves to the highest one
    /// it can, so the download stays small.
    private func clamp() {
        guard !formats.contains(where: { $0.rawValue == quality }) else { return }
        let wasSmaller = quality != DownloadFormat.original.rawValue
        quality = (wasSmaller ? formats.first { $0 != .original } : nil)?.rawValue ?? DownloadFormat.original.rawValue
    }
}

/// A list of episodes was only partly added (see
/// `DownloadManager.EpisodeRegistrationResult.problem`).
private struct EpisodeDownloadProblem: LocalizedError {
    let errorDescription: String?
}

private enum SeriesDownloadSheet: Identifiable {
    case downloadOptions
    case monitor
    case episodeOptions

    var id: String {
        switch self {
        case .downloadOptions: return "downloadOptions"
        case .monitor: return "monitor"
        case .episodeOptions: return "episodeOptions"
        }
    }
}

private struct SeriesDownloadOptionsSheet: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]
    let selectedSeason: Season?
    let cachedEpisodesBySeason: [Int: [EpisodeListItem]]
    let posterThumbhash: String?
    let preferredPosterPath: String?
    let canDownloadSeason: Bool
    let canMonitorSeries: Bool
    let isMonitored: Bool
    /// Set when the sheet was opened from an episode page.
    let episodeTitle: String?
    let onMonitor: () -> Void
    let onEpisodeOptions: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var quality = DownloadFormat.original.rawValue
    /// The version season and series downloads use; nil is Auto.
    @State private var version: DownloadVersionPreference?
    /// Choose Version is reading the files of every Emby episode.
    @State private var isCheckingFiles = false
    @State private var confirmingCancel = false
    /// Seasons the page hadn't loaded, fetched when the sheet opens so
    /// Choose Version lists every version in the series.
    @State private var loadedEpisodesBySeason: [Int: [EpisodeListItem]] = [:]
    /// Every file of episodes Emby listed with one source, by content id.
    @State private var sourceFiles: [String: [EpisodeFile]] = [:]

    private var episodesBySeason: [Int: [EpisodeListItem]] {
        var merged = loadedEpisodesBySeason
        for (season, episodes) in cachedEpisodesBySeason where !episodes.isEmpty {
            merged[season] = episodes
        }
        guard !sourceFiles.isEmpty else { return merged }
        return merged.mapValues { episodes in
            episodes.map { episode in sourceFiles[episode.contentId].map(episode.withEveryFile) ?? episode }
        }
    }

    /// Versions among the series' episodes, for Choose Version.
    private var versions: [SeriesDownloadVersion] {
        SeriesDownloadVersion.versions(in: episodesBySeason.values.flatMap { $0 })
    }

    private var showsQuality: Bool { manager.availableFormats.count > 1 }

    /// Emby's conversion service, for accounts that can't transcode
    /// playback, picks its own source for a smaller download.
    private var isEmbyConversion: Bool {
        MediaServerProvider.active == .emby && quality != DownloadFormat.original.rawValue
            && manager.capability?.versionTranscodes == false
    }

    /// The version downloads use: Auto on Emby's conversion service.
    private var effectiveVersion: DownloadVersionPreference? { isEmbyConversion ? nil : version }

    /// "1080p · 10 Mbps · 1080p · H.264 · 8 episodes" under a Download row.
    private func rowDetail(episodes count: Int?) -> String {
        let versionLabel = effectiveVersion.flatMap { chosen in versions.first { $0.version == chosen }?.title } ?? "Auto version"
        let episodes = count.map { "\($0) episode\($0 == 1 ? "" : "s")" }
        return [manager.qualityLabel(rawValue: quality), versionLabel, episodes].compactMap { $0 }.joined(separator: " · ")
    }

    private var activeDownloadCount: Int {
        manager.activeRecords(seriesId: seriesId).count + manager.waitingDownloads.filter { $0.seriesId == seriesId }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                if !versions.isEmpty || showsQuality {
                    Section {
                        if !versions.isEmpty {
                            NavigationLink {
                                SeriesDownloadVersionPage(
                                    versions: versions,
                                    isChecking: isCheckingFiles,
                                    isEmbyConversion: isEmbyConversion,
                                    version: $version,
                                    onAppear: loadEverySourceFile
                                )
                            } label: {
                                optionLabel(
                                    title: "Choose Version",
                                    detail: SeriesDownloadVersion.rowDetail(versions, chosen: effectiveVersion),
                                    icon: "square.stack"
                                )
                            }
                            .disabled(isEmbyConversion)
                        }
                        if showsQuality {
                            DownloadQualityPicker(quality: $quality, versionHeight: effectiveVersion?.height)
                        }
                    } footer: {
                        if showsQuality {
                            Text(DownloadQualityPicker.footer(
                                quality: quality,
                                versionHeight: effectiveVersion?.height,
                                scope: "Applies to Download Season and Download All Episodes."
                            ))
                        }
                    }
                }

                Section {
                    if let episodeTitle {
                        optionButton(
                            title: "Download This Episode",
                            detail: "\(episodeTitle) · Choose version and quality",
                            icon: "arrow.down.to.line"
                        ) {
                            dismiss()
                            onEpisodeOptions()
                        }
                    }

                    if !availableSeasons.isEmpty {
                        NavigationLink {
                            SeriesSeasonDownloadPicker(
                                seriesId: seriesId,
                                seriesTitle: seriesTitle,
                                seasons: availableSeasons,
                                cachedEpisodesBySeason: episodesBySeason,
                                posterThumbhash: posterThumbhash,
                                preferredPosterPath: preferredPosterPath
                            )
                        } label: {
                            optionLabel(
                                title: "Choose Episodes",
                                detail: "Open a season and select episodes",
                                icon: "checklist"
                            )
                        }
                    }

                    if canDownloadSeason, let selectedSeason {
                        optionButton(
                            title: "Download Season \(selectedSeason.seasonNumber)",
                            detail: rowDetail(episodes: selectedSeason.episodeCount),
                            icon: "arrow.down.square.on.square"
                        ) {
                            download(seasons: [selectedSeason], wholeSeries: false)
                        }
                    }

                    optionButton(
                        title: "Download All Episodes",
                        detail: rowDetail(episodes: nil),
                        icon: "arrow.down.circle"
                    ) {
                        download(seasons: availableSeasons, wholeSeries: true)
                    }
                } header: {
                    Text("Download")
                } footer: {
                    if !showsQuality {
                        Text("Downloads use original quality. Smaller qualities appear when the server allows download transcoding.")
                    }
                }

                if activeDownloadCount > 0 {
                    Section {
                        Button(role: .destructive) {
                            confirmingCancel = true
                        } label: {
                            Label(
                                activeDownloadCount == 1 ? "Cancel Download" : "Cancel \(activeDownloadCount) Downloads",
                                systemImage: "xmark.circle"
                            )
                        }
                    } footer: {
                        Text("Stops this series' unfinished downloads. Finished episodes are kept.")
                    }
                }

                if canMonitorSeries {
                    Section("Monitoring") {
                        optionButton(
                            title: isMonitored ? "Edit Monitoring" : "Monitor Series",
                            detail: isMonitored ? "Change auto-download rules" : "Auto-download future episodes",
                            icon: "antenna.radiowaves.left.and.right"
                        ) {
                            dismiss()
                            onMonitor()
                        }
                        if isMonitored {
                            Button(role: .destructive) {
                                if let sub = manager.subscription(forSeriesId: seriesId) {
                                    Task { await manager.deleteSubscription(id: sub.id) }
                                }
                                dismiss()
                            } label: {
                                Label("Stop Monitoring", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle(seriesTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .vividScrollContentBackgroundHidden()
            #if os(iOS)
            .background(Color.clear)
            #else
            .vividPageBackground()
            #endif
            .toolbar {
                VividSheetCloseItem { dismiss() }
            }
            .task {
                // Straight after launch or a server switch the permission may
                // not be loaded yet; the season and quality options need it.
                _ = await manager.prepareForDownload()
            }
            .task {
                // Versions don't wait on the permission check above, which can
                // be slow.
                await loadSourceFiles()
                await loadRemainingSeasons()
                await loadSourceFiles()
            }
            .confirmationDialog(
                activeDownloadCount == 1 ? "Cancel this download?" : "Cancel \(activeDownloadCount) downloads?",
                isPresented: $confirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel Downloads", role: .destructive) { manager.cancelActiveDownloads(seriesId: seriesId) }
                Button("Keep Downloading", role: .cancel) {}
            } message: {
                Text("Finished episodes are kept.")
            }
        }
        .vividGlassSheet()
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Auto uses one season or series request, at original or a smaller
    /// quality the server takes for batches. Otherwise each episode is
    /// registered on its own, with its file in the chosen version.
    private func download(seasons: [Season], wholeSeries: Bool) {
        let quality = quality
        let version = effectiveVersion
        let batch = version == nil && (quality == DownloadFormat.original.rawValue || manager.canChooseBatchQuality)
        startDownload {
            guard batch else {
                try await downloadEpisodes(seasons: seasons, quality: quality, version: version)
                return
            }
            do {
                if wholeSeries {
                    try await manager.downloadSeries(
                        seriesId: seriesId,
                        seriesTitle: seriesTitle,
                        posterThumbhash: posterThumbhash,
                        preferredPosterPath: preferredPosterPath,
                        quality: quality
                    )
                } else if let season = seasons.first {
                    try await manager.downloadSeason(
                        seriesId: seriesId,
                        seasonNumber: season.seasonNumber,
                        seriesTitle: seriesTitle,
                        posterThumbhash: posterThumbhash,
                        preferredPosterPath: preferredPosterPath,
                        quality: quality
                    )
                }
            } catch where DownloadError.isAccountLimit(error) {
                // Silo refuses a whole batch past the account's limit; one
                // episode at a time, the rest wait their turn.
                try await downloadEpisodes(seasons: seasons, quality: quality, version: nil)
            }
        }
    }

    /// Registers each episode on the account the tap was made on.
    private func downloadEpisodes(seasons: [Season], quality: String, version: DownloadVersionPreference?) async throws {
        let scope = await DownloadScope.current()
        var episodes: [EpisodeListItem] = []
        for season in seasons {
            if let known = episodesBySeason[season.seasonNumber], !known.isEmpty {
                episodes += known
            } else {
                episodes += try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: season.seasonNumber).episodes
            }
        }
        let result = await manager.downloadEpisodes(
            episodes.sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) },
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            posterThumbhash: posterThumbhash,
            preferredPosterPath: preferredPosterPath,
            quality: quality,
            version: version,
            scope: scope
        )
        if let problem = result.problem { throw EpisodeDownloadProblem(errorDescription: problem) }
    }

    /// Fetches the seasons the page hadn't loaded, one at a time.
    private func loadRemainingSeasons() async {
        for season in availableSeasons where episodesBySeason[season.seasonNumber]?.isEmpty != false {
            guard !Task.isCancelled else { return }
            if let response = try? await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: season.seasonNumber) {
                loadedEpisodesBySeason[season.seasonNumber] = response.episodes
            }
        }
    }

    /// Emby lists one source per episode. Fetches every file of the first
    /// episode in each season, then the rest of the selected season, so the
    /// menu lists the series' versions. A version download fetches any other
    /// episode's files when it registers it.
    private func loadSourceFiles() async {
        guard !EpisodeSourceFiles.listsEveryFile else { return }
        let scope = await DownloadScope.current()
        let selected = selectedSeason?.seasonNumber ?? availableSeasons.first?.seasonNumber
        let withFile = episodesBySeason.mapValues { $0.filter { $0.files?.isEmpty == false } }
        let firsts = withFile.sorted { ($0.key == selected ? 0 : 1, $0.key) < ($1.key == selected ? 0 : 1, $1.key) }
            .compactMap(\.value.first?.contentId)
        let rest = selected.flatMap { withFile[$0] }?.map(\.contentId) ?? []
        for ids in [firsts, rest] {
            let missing = ids.filter { sourceFiles[$0] == nil }
            guard !missing.isEmpty else { continue }
            let found = await EpisodeSourceFiles.fetch(missing)
            guard !Task.isCancelled, await DownloadScope.current() == scope else { return }
            sourceFiles.merge(found) { _, new in new }
        }
    }

    /// Choose Version counts every episode, so on Emby it reads the files of
    /// the episodes not read yet.
    private func loadEverySourceFile() async {
        guard !EpisodeSourceFiles.listsEveryFile, !isCheckingFiles else { return }
        let ids = episodesBySeason.values.flatMap { $0 }
            .filter { !$0.hasEveryFile && $0.files?.isEmpty == false }
            .map(\.contentId)
        guard !ids.isEmpty else { return }
        isCheckingFiles = true
        defer { isCheckingFiles = false }
        let scope = await DownloadScope.current()
        let found = await EpisodeSourceFiles.fetch(ids)
        guard !Task.isCancelled, await DownloadScope.current() == scope else { return }
        sourceFiles.merge(found) { _, new in new }
    }

    private var availableSeasons: [Season] {
        let sorted = seasons.sortedForDisplay()
        if sorted.isEmpty, let selectedSeason { return [selectedSeason] }
        return sorted
    }

    /// Run a download request, dismissing only on success — a silent
    /// `try?` here made an offline/unauthenticated tap look like it worked.
    private func startDownload(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func optionButton(
        title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            optionLabel(title: title, detail: detail, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(title: String, detail: String, icon: String) -> some View {
        DownloadOptionRow(title: title, detail: detail, icon: icon)
    }
}

/// An icon row with a title, detail line and chevron. The series and movie
/// download sheets share it.
struct DownloadOptionRow: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.vividOnSurface)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.vividOnSurface)
                Text(detail)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.vividSecondaryText)
        }
        .padding(.vertical, 4)
    }
}

/// First level of the single-episode flow. Keeping seasons as navigation
/// destinations makes the download sheet scale to long-running series without
/// turning the first screen into one enormous checklist.
private struct SeriesSeasonDownloadPicker: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]
    let cachedEpisodesBySeason: [Int: [EpisodeListItem]]
    let posterThumbhash: String?
    let preferredPosterPath: String?

    var body: some View {
        List {
            Section {
                ForEach(seasons.sortedForDisplay()) { season in
                    NavigationLink {
                        SeriesEpisodeDownloadPicker(
                            seriesId: seriesId,
                            seriesTitle: seriesTitle,
                            season: season,
                            initialEpisodes: cachedEpisodesBySeason[season.seasonNumber] ?? [],
                            posterThumbhash: posterThumbhash,
                            preferredPosterPath: preferredPosterPath
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(season.downloadDisplayName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.vividOnSurface)
                            Text("\(season.episodeCount) episode\(season.episodeCount == 1 ? "" : "s")")
                                .font(.vividCaption)
                                .foregroundColor(.vividSecondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Select a season")
            }
        }
        .navigationTitle("Choose Episodes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .vividScrollContentBackgroundHidden()
        #if os(iOS)
        .background(Color.clear)
        #else
        .vividPageBackground()
        #endif
    }
}

/// Native multi-selection for one season. A season's episode list is reused
/// from the detail model when available and fetched on demand otherwise.
private struct SeriesEpisodeDownloadPicker: View {
    let seriesId: String
    let seriesTitle: String
    let season: Season
    let posterThumbhash: String?
    let preferredPosterPath: String?

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var episodes: [EpisodeListItem]
    @State private var selectedEpisodeIds: Set<String> = []
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var quality = DownloadFormat.original.rawValue
    /// The version the selected episodes use; nil is Auto.
    @State private var version: DownloadVersionPreference?

    init(
        seriesId: String,
        seriesTitle: String,
        season: Season,
        initialEpisodes: [EpisodeListItem],
        posterThumbhash: String?,
        preferredPosterPath: String?
    ) {
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.season = season
        self.posterThumbhash = posterThumbhash
        self.preferredPosterPath = preferredPosterPath
        _episodes = State(initialValue: Self.sorted(initialEpisodes))
    }

    /// Versions among this season's episodes, for Choose Version.
    private var versions: [SeriesDownloadVersion] { SeriesDownloadVersion.versions(in: episodes) }

    private var showsQuality: Bool { manager.availableFormats.count > 1 }

    /// Emby's conversion service, for accounts that can't transcode
    /// playback, picks its own source for a smaller download.
    private var isEmbyConversion: Bool {
        MediaServerProvider.active == .emby && quality != DownloadFormat.original.rawValue
            && manager.capability?.versionTranscodes == false
    }

    private var effectiveVersion: DownloadVersionPreference? { isEmbyConversion ? nil : version }

    private var selectableEpisodeIds: Set<String> {
        Set(episodes.compactMap { episode in
            isSelectable(episode) ? episode.contentId : nil
        })
    }

    private var selectedEpisodes: [EpisodeListItem] {
        episodes.filter {
            selectedEpisodeIds.contains($0.contentId) && isSelectable($0)
        }
    }

    private var allSelectableAreSelected: Bool {
        !selectableEpisodeIds.isEmpty
            && selectableEpisodeIds.isSubset(of: selectedEpisodeIds)
    }

    var body: some View {
        Group {
            if isLoading, episodes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading episodes…")
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if episodes.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No Episodes",
                    subtitle: "No downloadable episodes were found for this season."
                )
            } else {
                List {
                    if !versions.isEmpty || showsQuality {
                        Section {
                            if !versions.isEmpty {
                                NavigationLink {
                                    SeriesDownloadVersionPage(
                                        versions: versions,
                                        isChecking: false,
                                        isEmbyConversion: isEmbyConversion,
                                        version: $version
                                    )
                                } label: {
                                    DownloadOptionRow(
                                        title: "Choose Version",
                                        detail: SeriesDownloadVersion.rowDetail(versions, chosen: effectiveVersion),
                                        icon: "square.stack"
                                    )
                                }
                                .disabled(isWorking || isEmbyConversion)
                            }
                            if showsQuality {
                                DownloadQualityPicker(quality: $quality, versionHeight: effectiveVersion?.height)
                                    .disabled(isWorking)
                            }
                        } footer: {
                            if showsQuality {
                                Text(DownloadQualityPicker.footer(quality: quality, versionHeight: effectiveVersion?.height))
                            }
                        }
                    }
                    Section {
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                        }
                    } header: {
                        HStack {
                            Text("Episodes")
                            Spacer()
                            if !selectableEpisodeIds.isEmpty {
                                Button(allSelectableAreSelected ? "Clear" : "Select All") {
                                    toggleSelectAll()
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
                .vividScrollContentBackgroundHidden()
            }
        }
        #if os(iOS)
        .background(Color.clear)
        #else
        .vividPageBackground()
        #endif
        .navigationTitle(season.downloadDisplayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            if !episodes.isEmpty {
                downloadBar
            }
        }
        .task {
            // Reached quickly from the series sheet, the permission and its
            // qualities may still be loading.
            _ = await manager.prepareForDownload()
        }
        .task {
            await loadEpisodesIfNeeded()
            await loadSourceFiles()
        }
        .alert(
            "Couldn't Continue",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var downloadBar: some View {
        Button(action: startSelectedDownloads) {
            HStack(spacing: 9) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.to.line")
                }
                Text(downloadButtonTitle)
                    .fontWeight(.bold)
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .downloadMenuActionSurface(cornerRadius: 15, isEnabled: !selectedEpisodes.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(selectedEpisodes.isEmpty || isWorking)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var downloadButtonTitle: String {
        let count = selectedEpisodes.count
        if count == 0 { return "Select Episodes" }
        return "Download \(count) Episode\(count == 1 ? "" : "s")"
    }

    private func episodeRow(_ episode: EpisodeListItem) -> some View {
        let selectable = isSelectable(episode)
        return Button {
            guard selectable, !isWorking else { return }
            toggle(episode.contentId)
        } label: {
            HStack(spacing: 12) {
                selectionIndicator(for: episode)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title ?? "Episode \(episode.episodeNumber)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.vividOnSurface)
                        .lineLimit(1)
                    Text(episodeDetailText(episode))
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let status = statusText(for: episode) {
                    Text(status)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusTint(for: episode))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable || isWorking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episodeAccessibilityLabel(episode))
        .accessibilityValue(episodeAccessibilityValue(episode))
        .accessibilityAddTraits(
            selectedEpisodeIds.contains(episode.contentId) ? .isSelected : []
        )
        .accessibilityHint(
            selectable ? "Double tap to toggle this episode for download." : ""
        )
    }

    @ViewBuilder
    private func selectionIndicator(for episode: EpisodeListItem) -> some View {
        if manager.isRegistering(contentId: episode.contentId) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else if let record = manager.record(forContentId: episode.contentId) {
            Image(systemName: statusIcon(for: record.localStatus))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(statusTint(for: episode))
                .frame(width: 24, height: 24)
        } else if manager.isWaiting(contentId: episode.contentId) {
            Image(systemName: statusIcon(for: .waiting))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(statusTint(for: episode))
                .frame(width: 24, height: 24)
        } else {
            DownloadSelectionCircle(selected: selectedEpisodeIds.contains(episode.contentId))
        }
    }

    private func episodeDetailText(_ episode: EpisodeListItem) -> String {
        var parts = ["Episode \(episode.episodeNumber)"]
        if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.joined(separator: " · ")
    }

    private func episodeAccessibilityLabel(_ episode: EpisodeListItem) -> String {
        let details = episodeDetailText(episode)
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return details
        }
        return "\(title), \(details)"
    }

    private func episodeAccessibilityValue(_ episode: EpisodeListItem) -> String {
        if let status = statusText(for: episode) { return status }
        return selectedEpisodeIds.contains(episode.contentId) ? "Selected" : "Not selected"
    }

    private func statusText(for episode: EpisodeListItem) -> String? {
        if manager.isRegistering(contentId: episode.contentId) { return "Preparing" }
        if manager.isWaiting(contentId: episode.contentId) { return "Waiting" }
        guard let record = manager.record(forContentId: episode.contentId) else { return nil }
        switch record.localStatus {
        case .registering, .preparing, .queued, .fetchingAssets, .waiting: return "Preparing"
        case .downloading: return "\(Int((record.progressFraction * 100).rounded()))%"
        case .paused: return "Paused"
        case .completed, .revoked: return "Downloaded"
        case .failed: return "Failed"
        }
    }

    private func statusIcon(for status: LocalDownloadStatus) -> String {
        switch status {
        case .registering, .preparing, .queued, .fetchingAssets, .waiting: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed, .revoked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func statusTint(for episode: EpisodeListItem) -> Color {
        guard let status = manager.record(forContentId: episode.contentId)?.localStatus else {
            return .vividSecondaryText
        }
        switch status {
        case .completed, .revoked: return .green
        case .failed: return .orange
        default: return .vividOnSurface.opacity(0.78)
        }
    }

    private func isSelectable(_ episode: EpisodeListItem) -> Bool {
        manager.record(forContentId: episode.contentId) == nil
            && !manager.isRegistering(contentId: episode.contentId)
            && !manager.isWaiting(contentId: episode.contentId)
    }

    private func toggle(_ contentId: String) {
        if selectedEpisodeIds.contains(contentId) {
            selectedEpisodeIds.remove(contentId)
        } else {
            selectedEpisodeIds.insert(contentId)
        }
    }

    private func toggleSelectAll() {
        if allSelectableAreSelected {
            selectedEpisodeIds.subtract(selectableEpisodeIds)
        } else {
            selectedEpisodeIds.formUnion(selectableEpisodeIds)
        }
    }

    /// Emby lists one source per episode; fetches every file of the
    /// season's episodes so the menu lists their versions.
    private func loadSourceFiles() async {
        guard !EpisodeSourceFiles.listsEveryFile else { return }
        let scope = await DownloadScope.current()
        let ids = episodes.filter { !$0.hasEveryFile && $0.files?.isEmpty == false }.map(\.contentId)
        guard !ids.isEmpty else { return }
        let found = await EpisodeSourceFiles.fetch(ids)
        guard !Task.isCancelled, await DownloadScope.current() == scope else { return }
        episodes = episodes.map { episode in found[episode.contentId].map(episode.withEveryFile) ?? episode }
    }

    private func loadEpisodesIfNeeded() async {
        guard episodes.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await VividAPI.shared.episodes(
                seriesId: seriesId,
                seasonNumber: season.seasonNumber
            )
            guard !Task.isCancelled else { return }
            episodes = Self.sorted(response.episodes)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSelectedDownloads() {
        let targets = selectedEpisodes
        guard !targets.isEmpty, !isWorking else { return }
        // One choice applies to the whole selection.
        let quality = quality
        let version = effectiveVersion
        isWorking = true
        Task {
            let result = await manager.downloadEpisodes(
                targets,
                seriesId: seriesId,
                seriesTitle: seriesTitle,
                posterThumbhash: posterThumbhash,
                preferredPosterPath: preferredPosterPath,
                quality: quality,
                version: version
            )
            selectedEpisodeIds = selectedEpisodeIds.filter { id in
                episodes.contains { $0.contentId == id && isSelectable($0) }
            }
            isWorking = false
            if let problem = result.problem {
                errorMessage = problem
            } else {
                dismiss()
            }
        }
    }

    private static func sorted(_ episodes: [EpisodeListItem]) -> [EpisodeListItem] {
        episodes.sorted { lhs, rhs in
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.contentId < rhs.contentId
        }
    }
}

/// Create / edit a series-monitoring subscription. The retention fields
/// (`delete_watched`, `max_storage_bytes`) are client-enforced; the server
/// only soft-gates auto-registration.
struct SeriesMonitorSheet: View {
    let seriesId: String
    let seriesTitle: String
    let seasons: [Season]

    @Environment(\.dismiss) private var dismiss
    private var manager: DownloadManager { DownloadManager.shared }

    @State private var mode: SubscriptionMode = .all
    @State private var selectedSeasons: Set<Int> = []
    @State private var deleteWatched: Bool = DownloadSettings.shared.defaultDeleteWatched
    @State private var maxStorageGB: Int = DownloadSettings.shared.defaultMaxStorageGB
    @State private var isSaving = false
    @State private var saveError: String?

    private var existing: DownloadSubscription? { manager.subscription(forSeriesId: seriesId) }
    private var availableModes: [SubscriptionMode] {
        manager.monitoringModes.isEmpty ? SubscriptionMode.allCases : manager.monitoringModes
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Keep Downloaded") {
                    Picker("Episodes", selection: $mode) {
                        ForEach(availableModes, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if mode == .specificSeasons {
                        ForEach(seasons) { season in
                            Toggle("Season \(season.seasonNumber)", isOn: Binding(
                                get: { selectedSeasons.contains(season.seasonNumber) },
                                set: { isOn in
                                    if isOn { selectedSeasons.insert(season.seasonNumber) }
                                    else { selectedSeasons.remove(season.seasonNumber) }
                                }
                            ))
                            .tint(.vividAccent)
                        }
                    }
                }
                Section("Storage") {
                    Toggle("Delete watched episodes", isOn: $deleteWatched)
                        .tint(.vividAccent)
                    Picker("Limit", selection: $maxStorageGB) {
                        ForEach(storageLimitOptionsGB, id: \.self) { gb in
                            Text(gb == 0 ? "Unlimited" : "\(gb) GB").tag(gb)
                        }
                    }
                }
            }
            #if os(iOS)
            .vividScrollContentBackgroundHidden()
            .background(Color.clear)
            #endif
            .navigationTitle(existing == nil ? "Monitor Series" : "Edit Monitoring")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                VividSheetCloseItem { dismiss() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || (mode == .specificSeasons && selectedSeasons.isEmpty))
                }
            }
            .onAppear(perform: prefill)
            .alert(
                "Couldn't Save Monitoring",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .vividGlassSheet(startsTall: true)
    }

    /// Common caps, plus the stored value when it doesn't match one —
    /// subscriptions written by the old stepper (or another client) must
    /// stay representable rather than silently snapping to a preset.
    private var storageLimitOptionsGB: [Int] {
        var options = [0, 10, 25, 50, 100]
        if !options.contains(maxStorageGB) {
            options.append(maxStorageGB)
            options.sort()
        }
        return options
    }

    private func prefill() {
        guard let existing else { return }
        mode = SubscriptionMode(rawValue: existing.mode) ?? .all
        selectedSeasons = Set(existing.seasonNumbers ?? [])
        deleteWatched = existing.deleteWatched
        maxStorageGB = Int(existing.maxStorageBytes / DownloadSettings.bytesPerGB)
    }

    private func save() {
        isSaving = true
        let bytes = Int64(maxStorageGB) * DownloadSettings.bytesPerGB
        let seasonNumbers = mode == .specificSeasons ? Array(selectedSeasons).sorted() : nil
        Task {
            do {
                if let existing {
                    try await manager.updateSubscription(
                        id: existing.id,
                        mode: mode,
                        seasonNumbers: seasonNumbers,
                        deleteWatched: deleteWatched,
                        maxStorageBytes: bytes,
                        active: true
                    )
                } else {
                    try await manager.createSubscription(
                        seriesId: seriesId,
                        seriesTitle: seriesTitle,
                        mode: mode,
                        seasonNumbers: seasonNumbers,
                        deleteWatched: deleteWatched,
                        maxStorageBytes: bytes
                    )
                }
                dismiss()
            } catch {
                // Keep the sheet up so the edits aren't lost — the user can
                // retry or cancel once they've seen why the save failed.
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
#endif
