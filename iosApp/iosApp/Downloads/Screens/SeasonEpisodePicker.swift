#if os(iOS)
import SwiftUI

extension DownloadScreens {
    /// Choose Episodes: the seasons to open.
    struct SeasonList: View {
        let seriesId: String
        let seriesTitle: String
        let seasons: [Season]
        let episodesBySeason: [Int: [EpisodeListItem]]
        let posterThumbhash: String?
        let posterPath: String?

        var body: some View {
            List {
                Section {
                    ForEach(seasons.sortedForDisplay()) { season in
                        NavigationLink {
                            EpisodePicker(
                                seriesId: seriesId,
                                seriesTitle: seriesTitle,
                                season: season,
                                episodes: episodesBySeason[season.seasonNumber] ?? [],
                                posterThumbhash: posterThumbhash,
                                posterPath: posterPath
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: season.downloadDisplayName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.vividOnSurface)
                                Text("\(season.episodeCount) episodes")
                                    .font(.vividCaption)
                                    .foregroundStyle(Color.vividSecondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Select a season")
                }
            }
            .navigationTitle("Choose Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .vividScrollContentBackgroundHidden()
            .background(Color.clear)
        }
    }

    /// Pick episodes of one season and download them together.
    struct EpisodePicker: View {
        let seriesId: String
        let seriesTitle: String
        let season: Season
        let posterThumbhash: String?
        let posterPath: String?

        @State private var episodes: [EpisodeListItem]
        @State private var selection: Set<String> = []
        @State private var isLoading = false
        @State private var isWorking = false
        @State private var errorMessage: String?
        @State private var quality = DownloadFormat.original.rawValue
        @State private var chosenVersion: DownloadVersionPreference?
        @Environment(\.dismiss) private var dismiss

        private var manager: DownloadManager { .shared }

        init(
            seriesId: String,
            seriesTitle: String,
            season: Season,
            episodes: [EpisodeListItem],
            posterThumbhash: String?,
            posterPath: String?
        ) {
            self.seriesId = seriesId
            self.seriesTitle = seriesTitle
            self.season = season
            self.posterThumbhash = posterThumbhash
            self.posterPath = posterPath
            _episodes = State(initialValue: Self.sorted(episodes))
        }

        var body: some View {
            content
                .navigationTitle(Text(verbatim: season.downloadDisplayName))
                .navigationBarTitleDisplayMode(.inline)
                .vividScrollContentBackgroundHidden()
                .background(Color.clear)
                .safeAreaInset(edge: .bottom) {
                    if !episodes.isEmpty { downloadBar }
                }
                .alert("Couldn't Continue", isPresented: errorShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(verbatim: errorMessage ?? "")
                }
                .task {
                    _ = await manager.prepareForDownload()
                }
                .task {
                    await loadIfNeeded()
                    await readEmbySourceFiles()
                }
        }

        @ViewBuilder
        private var content: some View {
            if isLoading && episodes.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading episodes…")
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
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
                    if !seasonVersions.isEmpty || offersSmaller {
                        versionAndQualitySection
                    }
                    episodesSection
                }
            }
        }

        // MARK: Sections

        private var versionAndQualitySection: some View {
            Section {
                if !seasonVersions.isEmpty {
                    NavigationLink {
                        SeriesDownloadVersionPage(
                            versions: seasonVersions,
                            isChecking: false,
                            isEmbyConversion: isEmbyConversion,
                            version: $chosenVersion
                        )
                    } label: {
                        OptionRow(
                            title: "Choose Version",
                            detail: SeriesDownloadVersion.rowDetail(seasonVersions, chosen: effectiveVersion),
                            symbol: "square.stack"
                        )
                    }
                    .disabled(isWorking || isEmbyConversion)
                }
                if showsQualityMenu {
                    QualityMenu(selection: $quality, versionHeight: effectiveVersion?.height)
                        .disabled(isWorking)
                }
            } footer: {
                if showsQualityMenu {
                    Text(verbatim: DownloadScreens.qualityFooter(
                        for: qualityUsed,
                        versionHeight: effectiveVersion?.height,
                        scopeLine: nil
                    ))
                } else if offersSmaller {
                    Text(verbatim: DownloadScreens.cantShrinkNote)
                }
            }
        }

        private var episodesSection: some View {
            let selectable = selectableIds
            let everySelected = !selectable.isEmpty && selectable.isSubset(of: selection)
            let toggleTitle: LocalizedStringKey = everySelected ? "Clear" : "Select All"
            return Section {
                ForEach(episodes) { episode in
                    row(for: episode)
                }
            } header: {
                HStack {
                    Text("Episodes")
                    Spacer()
                    if !selectable.isEmpty {
                        Button(toggleTitle) {
                            if everySelected {
                                selection.subtract(selectable)
                            } else {
                                selection.formUnion(selectable)
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
        }

        private func row(for episode: EpisodeListItem) -> some View {
            let canSelect = isSelectable(episode)
            let isSelected = selection.contains(episode.contentId)
            let status = statusText(for: episode)
            let tint = rowTint(for: episode)
            let detail = detailLine(for: episode)
            return Button {
                guard canSelect, !isWorking else { return }
                if isSelected {
                    selection.remove(episode.contentId)
                } else {
                    selection.insert(episode.contentId)
                }
            } label: {
                HStack(spacing: 12) {
                    indicator(for: episode, isSelected: isSelected, tint: tint)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: episode.title ?? String(localized: "Episode \(String(episode.episodeNumber))"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                        Text(verbatim: detail)
                            .font(.vividCaption)
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let status {
                        Text(verbatim: status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect || isWorking)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel(for: episode, detail: detail)))
            .accessibilityValue(Text(verbatim: status
                ?? (isSelected ? String(localized: "Selected") : String(localized: "Not selected"))))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(canSelect ? Text("Double tap to toggle this episode for download.") : Text(verbatim: ""))
        }

        @ViewBuilder
        private func indicator(for episode: EpisodeListItem, isSelected: Bool, tint: Color) -> some View {
            if manager.hasPendingRequest(contentId: episode.contentId) {
                ProgressView()
                    .controlSize(.small)
            } else if let record = manager.record(forContentId: episode.contentId) {
                Image(systemName: Self.statusSymbol(record.localStatus))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            } else if manager.isWaiting(contentId: episode.contentId) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                SelectionCircle(isSelected: isSelected)
            }
        }

        private var downloadBar: some View {
            let picked = selectedEpisodes
            let title = picked.isEmpty
                ? String(localized: "Select Episodes")
                : String(localized: "Download \(picked.count) Episodes")
            return Button(action: startDownload) {
                HStack(spacing: 9) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                    }
                    Text(verbatim: title)
                        .bold()
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .downloadMenuActionSurface(cornerRadius: 15, isEnabled: !picked.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(picked.isEmpty || isWorking)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }

        // MARK: Derived

        private var seasonVersions: [SeriesDownloadVersion] { SeriesDownloadVersion.versions(in: episodes) }

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

        /// Not downloaded, not being asked for and not waiting.
        private func isSelectable(_ episode: EpisodeListItem) -> Bool {
            manager.record(forContentId: episode.contentId) == nil
                && !manager.hasPendingRequest(contentId: episode.contentId)
                && !manager.isWaiting(contentId: episode.contentId)
        }

        private var selectableIds: Set<String> {
            Set(episodes.filter(isSelectable).map(\.contentId))
        }

        private var selectedEpisodes: [EpisodeListItem] {
            episodes.filter { selection.contains($0.contentId) && isSelectable($0) }
        }

        private func detailLine(for episode: EpisodeListItem) -> String {
            var parts = [String(localized: "Episode \(String(episode.episodeNumber))")]
            if let runtime = episode.runtime, runtime > 0 {
                parts.append(String(localized: "\(runtime) min"))
            }
            return parts.joined(separator: " · ")
        }

        private func accessibilityLabel(for episode: EpisodeListItem, detail: String) -> String {
            let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? detail : "\(title), \(detail)"
        }

        private func statusText(for episode: EpisodeListItem) -> String? {
            if manager.hasPendingRequest(contentId: episode.contentId) { return String(localized: "Preparing") }
            if manager.isWaiting(contentId: episode.contentId) { return String(localized: "Waiting") }
            guard let record = manager.record(forContentId: episode.contentId) else { return nil }
            switch record.localStatus {
            case .registering, .preparing, .queued, .fetchingAssets, .waiting:
                return String(localized: "Preparing")
            case .downloading:
                return Int((record.progressFraction * 100).rounded()).formatted(.percent)
            case .paused:
                return String(localized: "Paused")
            case .completed, .revoked:
                return String(localized: "Downloaded")
            case .failed:
                return String(localized: "Failed")
            }
        }

        private func rowTint(for episode: EpisodeListItem) -> Color {
            guard let record = manager.record(forContentId: episode.contentId) else { return .vividSecondaryText }
            switch record.localStatus {
            case .completed, .revoked: return .green
            case .failed: return .orange
            default: return Color.vividOnSurface.opacity(0.78)
            }
        }

        private static func statusSymbol(_ status: LocalDownloadStatus) -> String {
            switch status {
            case .registering, .preparing, .queued, .fetchingAssets, .waiting: return "arrow.down.circle"
            case .downloading: return "arrow.down.circle.fill"
            case .paused: return "pause.circle.fill"
            case .completed, .revoked: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }

        private static func sorted(_ list: [EpisodeListItem]) -> [EpisodeListItem] {
            list.sorted { ($0.episodeNumber, $0.contentId) < ($1.episodeNumber, $1.contentId) }
        }

        private var errorShown: Binding<Bool> {
            Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        }

        // MARK: Actions

        private func startDownload() {
            let picked = selectedEpisodes
            guard !picked.isEmpty, !isWorking else { return }
            let format = qualityUsed
            let version = effectiveVersion
            isWorking = true
            Task { @MainActor in
                let result = await manager.requestEpisodes(
                    picked,
                    seriesId: seriesId,
                    seriesTitle: seriesTitle,
                    posterThumbhash: posterThumbhash,
                    posterPath: posterPath,
                    quality: format.rawValue,
                    version: version,
                    scope: nil
                )
                let stillSelectable = selectableIds
                selection = selection.filter { stillSelectable.contains($0) }
                isWorking = false
                if let problem = result.problem {
                    errorMessage = problem
                } else {
                    dismiss()
                }
            }
        }

        private func loadIfNeeded() async {
            guard episodes.isEmpty, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let response = try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: season.seasonNumber)
                guard !Task.isCancelled else { return }
                episodes = Self.sorted(response.episodes)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                errorMessage = error.localizedDescription
            }
        }

        /// Emby lists one file per episode; read the rest so Choose Version
        /// sees every version.
        private func readEmbySourceFiles() async {
            guard !EpisodeSourceFiles.listsEveryFile else { return }
            let ids = episodes
                .filter { !$0.hasEveryFile && !($0.files ?? []).isEmpty }
                .map(\.contentId)
            guard !ids.isEmpty else { return }
            let scope = await DownloadScope.current()
            let found = await EpisodeSourceFiles.fetch(ids)
            guard !Task.isCancelled else { return }
            guard await DownloadScope.current() == scope else { return }
            episodes = episodes.map { episode in found[episode.contentId].map(episode.withEveryFile) ?? episode }
        }
    }
}
#endif
