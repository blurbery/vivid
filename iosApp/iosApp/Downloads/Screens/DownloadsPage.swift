#if os(iOS)
import SwiftUI

/// The Downloads tab: storage, downloads in progress, ones that need
/// attention, the downloaded series and movies, and monitored series.
struct DownloadsView: View {
    @Environment(AppRouter.self) private var router
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showsReclaim = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var showsCancelAll = false

    init() {}

    /// Downloads waiting on a confirmation to delete.
    private struct PendingDeletion {
        let ids: [String]
        /// Set when the select-mode bar asked, so confirming ends select mode.
        let endsSelecting: Bool
    }

    private var manager: DownloadManager { .shared }
    private var settings: DownloadSettings { .shared }

    var body: some View {
        content
            .background(VividAppBackdrop())
            .navigationTitle(isSelecting ? Text("\(selection.count) Selected") : Text("Downloads"))
            .navigationBarTitleDisplayMode(.large)
            .vividToolbarColorSchemeDark()
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty {
                    deleteSelectionBar
                }
            }
            .sheet(isPresented: $showsReclaim) {
                DownloadScreens.ReclaimSheet()
            }
            .confirmationDialog(
                "Delete downloaded files?",
                isPresented: pendingDeletionShown,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { pending in
                Button("Delete \(pending.ids.count) Downloads", role: .destructive) {
                    manager.remove(recordIds: pending.ids)
                    if pending.endsSelecting {
                        isSelecting = false
                        selection = []
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                if manager.downloadsEnabled {
                    await manager.refreshWatchedState()
                } else {
                    await manager.onAppActive()
                }
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if !manager.downloadsEnabled && manager.downloadsOffForAccount {
            EmptyStateView(
                icon: "arrow.down.circle",
                title: "Downloads Unavailable",
                subtitle: "Downloads aren't enabled for this account."
            )
        } else if !manager.downloadsEnabled && manager.hasFailedCheck && !manager.isCheckingDownloads {
            messageState(
                symbol: "exclamationmark.arrow.circlepath",
                title: "Couldn't Check Downloads",
                message: "The server didn't answer. Check your connection and try again.",
                buttonTitle: "Try Again"
            ) {
                Task { await manager.onAppActive() }
            }
        } else if !manager.downloadsEnabled {
            VStack(spacing: 14) {
                ProgressView()
                Text("Checking Downloads")
                    .font(.vividSubheadline)
                    .foregroundStyle(Color.vividOnSurface)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.records.isEmpty && manager.waitingDownloads.isEmpty && manager.monitoredSeries.isEmpty {
            messageState(
                symbol: "arrow.down.circle",
                title: "No Downloads",
                message: "Downloaded movies and episodes appear here for offline viewing.",
                buttonTitle: "Browse Libraries"
            ) {
                router.switchTab(to: .libraries)
            }
        } else {
            contentList
        }
    }

    private func messageState(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(Color.vividOnSurface.opacity(0.3))
            Text(title)
                .font(.vividSubheadline)
                .foregroundStyle(Color.vividOnSurface)
            Text(message)
                .font(.vividCaption)
                .foregroundStyle(Color.vividSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VividTheme.largePadding)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.vividChromeSelectedFill))
                    .overlay(Capsule().stroke(Color.vividChromeSelectedBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var contentList: some View {
        let unfinished = manager.unfinishedRecords
        let inProgress = unfinished + manager.waitingRecords
        let failed = manager.records.filter { $0.localStatus == .failed }
        let rows = shelfRows
        let seriesIds = Set(rows.compactMap { row -> String? in
            if case .show(let series) = row { return series.seriesId }
            return nil
        })
        let monitoring = manager.monitoredSeries.filter { !seriesIds.contains($0.seriesId) }
        return ScrollView {
            LazyVStack(spacing: 10) {
                DownloadScreens.StorageHeader(
                    usedBytes: manager.bytesOnDisk,
                    split: manager.storageSplit,
                    activeCount: unfinished.count + manager.waitingDownloads.count
                )
                .padding(.top, 6)
                if !isSelecting && !settings.keepsWatchedDownloads && manager.watchedBytesToClear > 0 {
                    DownloadScreens.ReclaimBanner(
                        count: manager.watchedToClear.count,
                        bytes: manager.watchedBytesToClear
                    ) {
                        showsReclaim = true
                    }
                }
                if !inProgress.isEmpty {
                    inProgressHeader(count: inProgress.count)
                    ForEach(inProgress) { record in
                        DownloadScreens.InProgressCard(
                            record: record,
                            bytesPerSecond: manager.smoothedRate(forRecord: record.id),
                            onPauseResume: { pauseOrResume(record) },
                            onCancel: { cancel(record) }
                        )
                    }
                }
                if !failed.isEmpty {
                    sectionLabel(String(localized: "Needs Attention"), count: failed.count)
                    ForEach(failed) { record in
                        DownloadScreens.AttentionRow(
                            record: record,
                            onRetry: { manager.retryFailed(recordId: record.id) },
                            onDelete: { manager.remove(recordId: record.id) }
                        )
                    }
                }
                if !rows.isEmpty {
                    DownloadScreens.SortControl(order: listOrder, count: rows.count)
                }
                ForEach(rows) { row in
                    shelfRow(row)
                }
                if !monitoring.isEmpty {
                    sectionLabel(String(localized: "Monitoring"), count: monitoring.count)
                    ForEach(monitoring) { subscription in
                        DownloadScreens.MonitoringRow(subscription: subscription) {
                            Task { await manager.stopMonitoring(id: subscription.id) }
                        }
                    }
                }
                Color.clear
                    .frame(height: 24)
            }
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: isSelecting)
        }
        .reportsPageChromeScroll()
    }

    @ViewBuilder
    private func shelfRow(_ row: DownloadShelfEntry) -> some View {
        switch row {
        case .show(let series):
            DownloadScreens.SeriesCard(
                series: series,
                isSelecting: isSelecting,
                isSelected: selection.contains(row.id),
                isWatched: { manager.isFinishedWatching($0) },
                onToggleSelection: { toggleSelection(row.id) },
                onOpen: isSelecting ? nil : { router.navigate(to: .offlineSeriesBrowse(seriesId: series.seriesId)) },
                onPlay: { DownloadScreens.play($0, router: router) },
                onDelete: { manager.remove(recordId: $0.id) }
            )
            .contextMenu {
                if !isSelecting {
                    Button("Delete All Episodes", systemImage: "trash", role: .destructive) {
                        pendingDeletion = PendingDeletion(ids: row.recordIds, endsSelecting: false)
                    }
                }
            }
        case .film(let record):
            DownloadScreens.MovieRow(
                record: record,
                isSelecting: isSelecting,
                isSelected: selection.contains(row.id),
                isWatched: manager.isFinishedWatching(record)
            ) {
                if isSelecting {
                    toggleSelection(row.id)
                } else {
                    router.navigate(to: .offlineDownloadDetail(downloadId: record.id))
                }
            }
            .contextMenu {
                if !isSelecting {
                    Button("Delete Download", systemImage: "trash", role: .destructive) {
                        pendingDeletion = PendingDeletion(ids: [record.id], endsSelecting: false)
                    }
                }
            }
        }
    }

    private func inProgressHeader(count: Int) -> some View {
        HStack {
            Text("IN PROGRESS")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Color.vividSecondaryText)
            Spacer()
            if count > 1 && !isSelecting {
                Button("Cancel All") { showsCancelAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                    .padding(.trailing, 8)
                    .confirmationDialog(
                        "Cancel \(count) downloads?",
                        isPresented: $showsCancelAll,
                        titleVisibility: .visible
                    ) {
                        Button("Cancel Downloads", role: .destructive) {
                            manager.cancelEveryUnfinished()
                        }
                        Button("Keep Downloading", role: .cancel) {}
                    } message: {
                        Text("Finished downloads are kept.")
                    }
            }
            Text("\(count)")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.vividOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    /// A section label, already localised, shown in capitals with its count.
    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(verbatim: title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Color.vividSecondaryText)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.vividOnSurface.opacity(0.38))
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: Select mode

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            let rowIds = shelfRows.map(\.id)
            let everySelected = !rowIds.isEmpty && rowIds.allSatisfy(selection.contains)
            let toggleTitle: LocalizedStringKey = everySelected ? "Clear" : "Select All"
            ToolbarItem(placement: .navigation) {
                Button(toggleTitle) {
                    selection = everySelected ? [] : Set(rowIds)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") {
                    isSelecting = false
                    selection = []
                }
            }
        } else if !shelfRows.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    private var deleteSelectionBar: some View {
        let chosen = shelfRows.filter { selection.contains($0.id) }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.storedBytes }
        return Button {
            pendingDeletion = PendingDeletion(ids: chosen.flatMap(\.recordIds), endsSelecting: true)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "trash")
                Text("Delete \(selection.count) · Free \(DownloadScreens.byteText(bytes))")
                    .bold()
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .downloadMenuActionSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: Helpers

    private var shelfRows: [DownloadShelfEntry] {
        manager.shelfEntries(orderedBy: settings.listOrder)
    }

    private var listOrder: Binding<DownloadListOrder> {
        Binding(get: { settings.listOrder }, set: { settings.listOrder = $0 })
    }

    private var pendingDeletionShown: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// A paused download resumes; anything else is asked to pause.
    private func pauseOrResume(_ record: DownloadRecord) {
        if record.localStatus == .paused {
            manager.resumeTransfer(recordId: record.id)
        } else {
            manager.pauseTransfer(recordId: record.id)
        }
    }

    /// A waiting episode leaves the queue; anything else is deleted.
    private func cancel(_ record: DownloadRecord) {
        if record.localStatus == .waiting, let episodeId = record.episodeId {
            manager.cancelWaiting(id: episodeId)
        } else {
            manager.remove(recordId: record.id)
        }
    }
}
#endif
