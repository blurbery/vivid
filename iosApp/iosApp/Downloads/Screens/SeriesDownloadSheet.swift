#if os(iOS)
import SwiftUI

extension DownloadScreens {
    /// Download a season, the whole series or chosen episodes, cancel the
    /// series' downloads, and reach monitoring.
    struct SeriesSheet: View {
        let seriesId: String
        let seriesTitle: String
        let seasons: [Season]
        let selectedSeason: Season?
        let episodesBySeason: [Int: [EpisodeListItem]]
        let posterThumbhash: String?
        let posterPath: String?
        let allowsSeasonDownload: Bool
        let allowsMonitoring: Bool
        let isMonitored: Bool
        let episodeTitle: String?
        let onMonitor: () -> Void
        let onEpisodeOptions: () -> Void

        @State private var errorMessage: String?
        @State private var isWorking = false
        @State private var quality = DownloadFormat.original.rawValue
        @State private var chosenVersion: DownloadVersionPreference?
        @State private var isCheckingFiles = false
        @State private var showsCancelConfirmation = false
        @State private var loadedSeasons: [Int: [EpisodeListItem]] = [:]
        @State private var everyFile: [String: [EpisodeFile]] = [:]
        @Environment(\.dismiss) private var dismiss

        private var manager: DownloadManager { .shared }

        var body: some View {
            NavigationStack {
                Form {
                    if !seriesVersions.isEmpty || offersSmaller {
                        versionAndQualitySection
                    }
                    downloadSection
                    if activeCount > 0 {
                        cancelSection
                    }
                    if allowsMonitoring {
                        monitoringSection
                    }
                }
                .navigationTitle(Text(verbatim: seriesTitle))
                .navigationBarTitleDisplayMode(.inline)
                .vividScrollContentBackgroundHidden()
                .background(Color.clear)
                .toolbar {
                    VividSheetCloseItem { dismiss() }
                }
            }
            .vividGlassSheet()
            .confirmationDialog(
                "Cancel \(activeCount) downloads?",
                isPresented: $showsCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel Downloads", role: .destructive) {
                    manager.cancelUnfinished(inSeries: seriesId)
                }
                Button("Keep Downloading", role: .cancel) {}
            } message: {
                Text("Finished episodes are kept.")
            }
            .alert("Download Failed", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
            .task {
                // Loads the capability the season, quality and monitoring rows use.
                _ = await manager.prepareForDownload()
            }
            .task {
                await readEmbySourceFiles()
                await loadRemainingSeasons()
                await readEmbySourceFiles()
            }
        }

        // MARK: Sections

        private var versionAndQualitySection: some View {
            Section {
                if !seriesVersions.isEmpty {
                    NavigationLink {
                        SeriesDownloadVersionPage(
                            versions: seriesVersions,
                            isChecking: isCheckingFiles,
                            isEmbyConversion: isEmbyConversion,
                            version: $chosenVersion,
                            onAppear: { await readEveryFileForVersions() }
                        )
                    } label: {
                        OptionRow(
                            title: "Choose Version",
                            detail: SeriesDownloadVersion.rowDetail(seriesVersions, chosen: effectiveVersion),
                            symbol: "square.stack"
                        )
                    }
                    .disabled(isEmbyConversion)
                }
                if showsQualityMenu {
                    QualityMenu(selection: $quality, versionHeight: effectiveVersion?.height)
                }
            } footer: {
                if showsQualityMenu {
                    Text(verbatim: DownloadScreens.qualityFooter(
                        for: qualityUsed,
                        versionHeight: effectiveVersion?.height,
                        scopeLine: String(localized: "Applies to Download Season and Download All Episodes.")
                    ))
                } else if offersSmaller {
                    Text(verbatim: DownloadScreens.cantShrinkNote)
                }
            }
        }

        private var downloadSection: some View {
            Section {
                if let episodeTitle {
                    Button {
                        onEpisodeOptions()
                        dismiss()
                    } label: {
                        OptionRow(
                            title: "Download This Episode",
                            detail: String(localized: "\(episodeTitle) · Choose version and quality"),
                            symbol: "arrow.down.to.line"
                        )
                    }
                    .buttonStyle(.plain)
                }
                if !availableSeasons.isEmpty {
                    NavigationLink {
                        SeasonList(
                            seriesId: seriesId,
                            seriesTitle: seriesTitle,
                            seasons: availableSeasons,
                            episodesBySeason: mergedEpisodes,
                            posterThumbhash: posterThumbhash,
                            posterPath: posterPath
                        )
                    } label: {
                        OptionRow(
                            title: "Choose Episodes",
                            detail: String(localized: "Open a season and select episodes"),
                            symbol: "checklist"
                        )
                    }
                }
                if allowsSeasonDownload, let selectedSeason {
                    Button {
                        download([selectedSeason], wholeSeries: false)
                    } label: {
                        OptionRow(
                            title: "Download Season \(String(selectedSeason.seasonNumber))",
                            detail: rowDetail(count: selectedSeason.episodeCount),
                            symbol: "arrow.down.square.on.square"
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    download(availableSeasons, wholeSeries: true)
                } label: {
                    OptionRow(title: "Download All Episodes", detail: rowDetail(count: nil), symbol: "arrow.down.circle")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Download")
            } footer: {
                if !offersSmaller {
                    Text("Downloads use original quality. Smaller qualities appear when the server allows download transcoding.")
                }
            }
        }

        private var cancelSection: some View {
            Section {
                Button(role: .destructive) {
                    showsCancelConfirmation = true
                } label: {
                    Label("Cancel \(activeCount) Downloads", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Stops this series' unfinished downloads. Finished episodes are kept.")
            }
        }

        private var monitoringSection: some View {
            let title: LocalizedStringKey = isMonitored ? "Edit Monitoring" : "Monitor Series"
            let detail = isMonitored
                ? String(localized: "Change auto-download rules")
                : String(localized: "Auto-download future episodes")
            return Section {
                Button {
                    onMonitor()
                    dismiss()
                } label: {
                    OptionRow(title: title, detail: detail, symbol: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.plain)
                if isMonitored {
                    Button(role: .destructive) {
                        if let subscription = manager.monitoring(forSeries: seriesId) {
                            Task { await manager.stopMonitoring(id: subscription.id) }
                        }
                        dismiss()
                    } label: {
                        Label("Stop Monitoring", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("Monitoring")
            }
        }

        // MARK: Derived

        /// Seasons fetched here, overridden by every season the page already
        /// had, with Emby episodes swapped for their every-file copies.
        private var mergedEpisodes: [Int: [EpisodeListItem]] {
            var map = loadedSeasons
            for (number, list) in episodesBySeason where !list.isEmpty {
                map[number] = list
            }
            guard !everyFile.isEmpty else { return map }
            return map.mapValues { list in
                list.map { episode in everyFile[episode.contentId].map(episode.withEveryFile) ?? episode }
            }
        }

        private var seriesVersions: [SeriesDownloadVersion] {
            let map = mergedEpisodes
            return SeriesDownloadVersion.versions(in: map.keys.sorted().flatMap { map[$0] ?? [] })
        }

        private var offersSmaller: Bool { manager.offeredQualities.count > 1 }

        private var isEmbyConversion: Bool { DownloadScreens.isEmbyConversion(storedQuality: quality) }

        private var effectiveVersion: DownloadVersionPreference? { isEmbyConversion ? nil : chosenVersion }

        private var qualitiesForVersion: [DownloadFormat] {
            DownloadScreens.qualities(forVersionHeight: effectiveVersion?.height)
        }

        private var showsQualityMenu: Bool { qualitiesForVersion.count > 1 }

        private var qualityUsed: DownloadFormat {
            DownloadScreens.qualityUsed(stored: quality, among: qualitiesForVersion)
        }

        private var availableSeasons: [Season] {
            let sorted = seasons.sortedForDisplay()
            if sorted.isEmpty, let selectedSeason { return [selectedSeason] }
            return sorted
        }

        private var activeCount: Int {
            manager.unfinishedRecords(inSeries: seriesId).count
                + manager.waitingDownloads.filter { $0.seriesId == seriesId }.count
        }

        private func rowDetail(count: Int?) -> String {
            var parts = [manager.qualityTitle(for: qualityUsed)]
            parts.append(seriesVersions.first { $0.version == effectiveVersion }?.title ?? String(localized: "Auto version"))
            if let count { parts.append(String(localized: "\(count) episodes")) }
            return parts.joined(separator: " · ")
        }

        private var errorShown: Binding<Bool> {
            Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        }

        // MARK: Downloading

        /// One request covers the seasons when the version is Auto and the
        /// quality can go in a batch; otherwise each episode is asked for.
        private func download(_ chosen: [Season], wholeSeries: Bool) {
            let format = qualityUsed
            let version = effectiveVersion
            let batch = version == nil && (format == .original || manager.allowsBatchQuality)
            guard !isWorking else { return }
            isWorking = true
            Task { @MainActor in
                do {
                    if batch {
                        do {
                            if wholeSeries {
                                try await manager.requestWholeSeries(
                                    seriesId: seriesId,
                                    seriesTitle: seriesTitle,
                                    posterThumbhash: posterThumbhash,
                                    posterPath: posterPath,
                                    quality: format.rawValue
                                )
                            } else if let season = chosen.first {
                                try await manager.requestSeason(
                                    season.seasonNumber,
                                    seriesId: seriesId,
                                    seriesTitle: seriesTitle,
                                    posterThumbhash: posterThumbhash,
                                    posterPath: posterPath,
                                    quality: format.rawValue
                                )
                            }
                        } catch where DownloadError.isAccountLimit(error) {
                            // Over the account's limit: ask episode by episode so the
                            // rest can wait their turn.
                            try await requestEachEpisode(of: chosen, quality: format, version: nil)
                        }
                    } else {
                        try await requestEachEpisode(of: chosen, quality: format, version: version)
                    }
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isWorking = false
            }
        }

        private func requestEachEpisode(
            of chosen: [Season],
            quality format: DownloadFormat,
            version: DownloadVersionPreference?
        ) async throws {
            let scope = await DownloadScope.current()
            var list: [EpisodeListItem] = []
            for season in chosen {
                if let known = mergedEpisodes[season.seasonNumber], !known.isEmpty {
                    list += known
                } else {
                    list += try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: season.seasonNumber).episodes
                }
            }
            list.sort { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }
            let result = await manager.requestEpisodes(
                list,
                seriesId: seriesId,
                seriesTitle: seriesTitle,
                posterThumbhash: posterThumbhash,
                posterPath: posterPath,
                quality: format.rawValue,
                version: version,
                scope: scope
            )
            if let problem = result.problem { throw ProblemText(text: problem) }
        }

        // MARK: Loading

        private func loadRemainingSeasons() async {
            for season in availableSeasons {
                guard !Task.isCancelled else { return }
                if let known = mergedEpisodes[season.seasonNumber], !known.isEmpty { continue }
                if let response = try? await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: season.seasonNumber) {
                    loadedSeasons[season.seasonNumber] = response.episodes
                }
            }
        }

        /// Emby lists one file per episode. Read a sample of each season
        /// first, then all of the selected season, so Choose Version can
        /// offer every version.
        private func readEmbySourceFiles() async {
            guard !EpisodeSourceFiles.listsEveryFile else { return }
            let scope = await DownloadScope.current()
            let selectedNumber = selectedSeason?.seasonNumber ?? availableSeasons.first?.seasonNumber
            let withFiles = mergedEpisodes
                .mapValues { list in list.filter { !($0.files ?? []).isEmpty } }
                .filter { !$0.value.isEmpty }
            var samples: [String] = []
            if let selectedNumber, let first = withFiles[selectedNumber]?.first {
                samples.append(first.contentId)
            }
            for number in withFiles.keys.sorted() where number != selectedNumber {
                if let first = withFiles[number]?.first { samples.append(first.contentId) }
            }
            let selectedAll = selectedNumber.flatMap { withFiles[$0] }?.map(\.contentId) ?? []
            for batch in [samples, selectedAll] {
                let ids = batch.filter { everyFile[$0] == nil }
                guard !ids.isEmpty else { continue }
                let found = await EpisodeSourceFiles.fetch(ids)
                guard !Task.isCancelled else { return }
                guard await DownloadScope.current() == scope else { return }
                everyFile.merge(found) { _, new in new }
            }
        }

        /// Choose Version's appear action on Emby: read every file of the
        /// episodes that list only one.
        private func readEveryFileForVersions() async {
            guard !EpisodeSourceFiles.listsEveryFile, !isCheckingFiles else { return }
            let map = mergedEpisodes
            let ids = map.keys.sorted()
                .flatMap { map[$0] ?? [] }
                .filter { !$0.hasEveryFile && !($0.files ?? []).isEmpty }
                .map(\.contentId)
            guard !ids.isEmpty else { return }
            isCheckingFiles = true
            defer { isCheckingFiles = false }
            let scope = await DownloadScope.current()
            let found = await EpisodeSourceFiles.fetch(ids)
            guard !Task.isCancelled else { return }
            guard await DownloadScope.current() == scope else { return }
            everyFile.merge(found) { _, new in new }
        }
    }

    /// A registration result's problem, shown in an alert.
    struct ProblemText: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
}
#endif
