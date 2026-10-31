#if os(iOS)
import SwiftUI

// MARK: - In progress

extension DownloadScreens {
    /// An unfinished download: what it is, how far along, and a ring to
    /// pause or resume. Cancelling asks first.
    struct InProgressCard: View {
        let record: DownloadRecord
        let bytesPerSecond: Double?
        let onPauseResume: () -> Void
        let onCancel: () -> Void

        @State private var showsCancelConfirmation = false

        private var manager: DownloadManager { .shared }

        var body: some View {
            SwipeToCancel(onCancel: { showsCancelConfirmation = true }) {
                card
            }
            .padding(.horizontal, 16)
            .contextMenu {
                if record.localStatus == .downloading {
                    Button("Pause", systemImage: "pause", action: onPauseResume)
                } else if record.localStatus == .paused {
                    Button("Resume", systemImage: "play", action: onPauseResume)
                }
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) {
                    showsCancelConfirmation = true
                }
            }
            .confirmationDialog(cancelTitle, isPresented: $showsCancelConfirmation, titleVisibility: .visible) {
                Button("Discard Download", role: .destructive, action: onCancel)
                Button("Keep Download", role: .cancel) {}
            }
        }

        private var card: some View {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            return HStack(spacing: 15) {
                PosterTile(
                    thumbhash: record.posterThumbhash,
                    file: manager.posterFile(for: record),
                    width: 66,
                    cornerRadius: 10
                )
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(verbatim: primaryTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                        KindChip(isSeries: isEpisode)
                    }
                    if let secondaryTitle {
                        Text(verbatim: secondaryTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(1)
                    }
                    if let barFraction {
                        progressBar(barFraction)
                    }
                    Text(verbatim: statusLine)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.vividOnSurface.opacity(0.52))
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                trailingControl
            }
            .padding(12)
            .background(Color.clear.vividGlass(in: shape, tint: Color.white.opacity(0.025)))
            .overlay(shape.stroke(Color.vividOnSurface.opacity(0.10), lineWidth: 1))
        }

        private func progressBar(_ fraction: Double) -> some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.vividOnSurface.opacity(0.12))
                    Capsule()
                        .fill(Color.vividOnSurface.opacity(record.localStatus == .paused ? 0.52 : 0.92))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 4)
        }

        @ViewBuilder
        private var trailingControl: some View {
            switch record.localStatus {
            case .downloading, .paused:
                let paused = record.localStatus == .paused
                Button(action: onPauseResume) {
                    ZStack {
                        Circle()
                            .stroke(Color.vividOnSurface.opacity(0.15), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: min(max(record.progressFraction, 0.02), 1))
                            .stroke(Color.vividOnSurface.opacity(paused ? 0.55 : 1),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if !paused {
                            ActivityArc(diameter: 36, lineWidth: 3)
                        }
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.vividOnSurface)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paused ? Text("Resume download") : Text("Pause download"))
            default:
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.vividOnSurface)
            }
        }

        // MARK: Text

        private var isEpisode: Bool { record.type == "episode" }

        private var primaryTitle: String {
            if isEpisode { return record.seriesTitle ?? record.title ?? record.contentId }
            return record.title ?? record.contentId
        }

        private var secondaryTitle: String? {
            guard isEpisode else { return record.subtitle }
            let primary = primaryTitle
            let parts = [record.subtitle, record.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != primary }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private var barFraction: Double? {
            switch record.localStatus {
            case .downloading, .paused:
                return record.progressFraction
            case .preparing:
                return record.preparation?.progress.map { min(max($0, 0), 1) }
            default:
                return nil
            }
        }

        private var statusLine: String {
            switch record.localStatus {
            case .downloading:
                let rates = rateTexts
                if record.bytesDownloaded == 0 && rates.isEmpty {
                    return String(localized: "Waiting to download…")
                }
                return ([percentText, sizeText] + rates).joined(separator: " · ")
            case .paused:
                return String(localized: "Paused · \(percentText) · \(sizeText)")
            case .registering, .queued:
                return String(localized: "Queued")
            case .preparing:
                return record.preparation?.statusText ?? String(localized: "Preparing on server…")
            case .fetchingAssets:
                return String(localized: "Starting…")
            case .waiting:
                return String(localized: "Waiting for your server")
            case .completed:
                return DownloadScreens.byteText(record.fileSize)
            case .failed:
                return String(localized: "Failed")
            case .revoked:
                return String(localized: "No longer available")
            }
        }

        private var percentText: String {
            Int((record.progressFraction * 100).rounded()).formatted(.percent)
        }

        private var sizeText: String {
            let done = DownloadScreens.byteText(record.bytesDownloaded)
            let total = DownloadScreens.byteText(record.fileSize)
            return String(localized: "\(done) of \(total)", comment: "Downloaded size of total size, e.g. 1.2 GB of 4 GB")
        }

        /// The speed and, when there's anything left, the time left.
        private var rateTexts: [String] {
            guard let bytesPerSecond, bytesPerSecond >= 1 else { return [] }
            let speed = DownloadScreens.byteText(Int64(bytesPerSecond))
            var texts = [String(localized: "\(speed)/s", comment: "Download speed, e.g. 12 MB/s")]
            let remaining = record.fileSize - record.bytesDownloaded
            if remaining > 0 {
                let minutes = Int((Double(remaining) / bytesPerSecond / 60).rounded())
                if minutes == 0 {
                    texts.append(String(localized: "under 1 min left"))
                } else if minutes < 60 {
                    texts.append(String(localized: "\(minutes) min left"))
                } else {
                    texts.append(String(localized: "\(minutes / 60) hr \(minutes % 60) min left"))
                }
            }
            return texts
        }

        private var cancelTitle: String {
            guard record.bytesDownloaded > 0 else { return String(localized: "Cancel this download?") }
            return String(localized: "Discard \(DownloadScreens.byteText(record.bytesDownloaded)) of downloaded data?")
        }
    }
}

/// The page scrolls rather than being a list, so the in-progress cards draw
/// their own trailing swipe: drag left to reveal Cancel.
private struct SwipeToCancel<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var isOpen = false

    private static var revealWidth: CGFloat { 84 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                close()
                onCancel()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .frame(width: Self.revealWidth - 8)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.vividError))
            }
            .buttonStyle(.plain)
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)

            content
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: close)
                    }
                }
                .offset(x: offset)
                .animation(.easeInOut(duration: 0.2), value: offset)
                .simultaneousGesture(drag)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let origin = dragOrigin ?? (isOpen ? -Self.revealWidth : 0)
                dragOrigin = origin
                offset = min(0, max(-Self.revealWidth, origin + value.translation.width))
            }
            .onEnded { _ in
                dragOrigin = nil
                let opens = -offset > Self.revealWidth / 2
                offset = opens ? -Self.revealWidth : 0
                isOpen = opens
            }
    }

    private func close() {
        offset = 0
        isOpen = false
    }
}

// MARK: - Rows

extension DownloadScreens {
    /// A download that failed for good, with retry and delete.
    struct AttentionRow: View {
        let record: DownloadRecord
        let onRetry: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                PosterTile(
                    thumbhash: record.posterThumbhash,
                    file: DownloadManager.shared.posterFile(for: record),
                    width: 40,
                    cornerRadius: 7
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: record.title ?? record.contentId)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    Text("Download failed")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.vividError)
                }
                Spacer(minLength: 8)
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.vividSecondaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .downloadGlassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
        }
    }

    /// A monitored series with nothing downloaded yet.
    struct MonitoringRow: View {
        let subscription: MonitoredSeries
        let onStop: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.vividOnSurface)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: subscription.seriesTitle ?? subscription.seriesId)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    Text(verbatim: MonitoringRule(rawValue: subscription.mode)?.title ?? subscription.mode)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .downloadGlassCard(cornerRadius: 16)
            .contextMenu {
                Button("Stop Monitoring", systemImage: "xmark.circle", role: .destructive, action: onStop)
            }
            .padding(.horizontal, 16)
        }
    }

    /// A downloaded movie.
    struct MovieRow: View {
        let record: DownloadRecord
        let isSelecting: Bool
        let isSelected: Bool
        let isWatched: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    if isSelecting {
                        SelectionCircle(isSelected: isSelected)
                    }
                    PosterTile(
                        thumbhash: record.posterThumbhash,
                        file: DownloadManager.shared.posterFile(for: record),
                        width: 40
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(verbatim: record.title ?? record.contentId)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.vividOnSurface)
                                .lineLimit(1)
                            KindChip(isSeries: false)
                        }
                        if !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.vividSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: DownloadScreens.byteText(record.fileSize))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private var detail: String {
            var parts: [String] = []
            if let subtitle = record.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
            if isWatched {
                parts.append(String(
                    localized: "watched",
                    comment: "Lowercase status after a movie's details in the downloads list, e.g. 2024 · watched"
                ))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// A downloaded series. The chevron opens its episodes in place; the
    /// header opens the series page.
    struct SeriesCard: View {
        let series: DownloadedSeries
        let isSelecting: Bool
        let isSelected: Bool
        let isWatched: (DownloadRecord) -> Bool
        let onToggleSelection: () -> Void
        let onOpen: (() -> Void)?
        let onPlay: (DownloadRecord) -> Void
        let onDelete: (DownloadRecord) -> Void

        @State private var isExpanded = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            VStack(spacing: 0) {
                header
                if isExpanded && !isSelecting {
                    ForEach(series.seasonGroups) { season in
                        Divider()
                            .overlay(Color.vividDivider)
                        seasonHeader(season)
                        ForEach(season.episodes) { record in
                            EpisodeRow(
                                record: record,
                                isWatched: isWatched(record),
                                onPlay: { onPlay(record) },
                                onDelete: { onDelete(record) }
                            )
                        }
                    }
                }
            }
            .downloadGlassCard(cornerRadius: 18, highlighted: isExpanded)
            .clipShape(shape)
            .padding(.horizontal, 16)
        }

        private var header: some View {
            HStack(spacing: 13) {
                if isSelecting {
                    SelectionCircle(isSelected: isSelected)
                }
                posterStack
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(verbatim: series.displayTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                        if series.hasMonitoring {
                            monitoringBadge
                        }
                    }
                    Text(verbatim: subtitleLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(verbatim: DownloadScreens.byteText(series.storedBytes))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                if !isSelecting {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.vividSecondaryText)
                            .frame(width: 26, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? Text("Collapse episodes") : Text("Expand episodes"))
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    onToggleSelection()
                } else {
                    onOpen?()
                }
            }
        }

        /// The poster with two cards fanned out behind it.
        private var posterStack: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.vividOnSurface.opacity(0.18))
                    .frame(width: 46, height: 62)
                    .offset(x: 9)
                    .opacity(0.45)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.vividOnSurface.opacity(0.22))
                    .frame(width: 46, height: 64)
                    .offset(x: 4)
                    .opacity(0.70)
                PosterTile(
                    thumbhash: series.artworkHash,
                    file: DownloadScreens.firstPosterFile(in: series.everyRecord),
                    width: 46,
                    cornerRadius: 7
                )
            }
            .frame(width: 59, height: 66, alignment: .leading)
        }

        private var monitoringBadge: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            return HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Monitoring")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(Color.vividOnSurface)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(shape.fill(Color.vividChromeRestingFill))
            .overlay(shape.stroke(Color.vividChromeRestingBorder, lineWidth: 1))
        }

        private func seasonHeader(_ season: DownloadedSeason) -> some View {
            HStack {
                Text(verbatim: DownloadScreens.seasonName(season))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                Spacer()
                Text(verbatim: String(
                    localized: "\(season.episodeTotal) eps · \(DownloadScreens.byteText(season.storedBytes))",
                    comment: "Downloaded episode count (abbreviated) and size for a season"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.vividSecondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 5)
        }

        private var subtitleLine: String {
            var parts = [String(localized: "\(series.episodeTotal) episodes")]
            if series.seasonTotal > 1 {
                parts.append(String(localized: "\(series.seasonTotal) seasons"))
            } else if let only = series.seasonGroups.first {
                parts.append(DownloadScreens.seasonName(only))
            }
            if series.fullyWatched {
                parts.append(String(localized: "all watched", comment: "Lowercase note after a downloaded series' episode count"))
            } else if series.watchedEpisodes > 0 {
                parts.append(String(
                    localized: "\(series.watchedEpisodes) watched",
                    comment: "Lowercase count of watched downloaded episodes, e.g. 3 watched"
                ))
            }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Page furniture

extension DownloadScreens {
    /// How much the downloads take up, on what's on the device, split into
    /// series, movies, unfinished downloads and the rest.
    struct StorageHeader: View {
        let usedBytes: Int64
        let split: StorageSplit
        let activeCount: Int

        /// Read once, when the header is first made.
        @State private var capacity = DeviceStorage.read().total

        private struct Segment: Identifiable {
            let id: Int
            let label: LocalizedStringKey
            let bytes: Int64
            let opacity: Double
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            VStack(alignment: .leading, spacing: 13) {
                headline
                    .font(.system(size: 14))
                    .foregroundStyle(Color.vividSecondaryText)
                if activeCount > 0 {
                    inProgressLine
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                if split.allBytes > 0 {
                    bar
                    legend
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.clear.vividGlass(in: shape, tint: Color.white.opacity(0.025)))
            .overlay(shape.stroke(Color.vividOnSurface.opacity(0.10), lineWidth: 1))
            .padding(.horizontal, 16)
        }

        private var headline: Text {
            let used = Text(verbatim: DownloadScreens.byteText(usedBytes))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.vividOnSurface)
            if capacity > 0 {
                let total = DownloadScreens.byteText(capacity)
                return Text(
                    "\(used)  of \(total) on this device",
                    comment: "Downloads storage summary, e.g. 12 GB of 128 GB on this device"
                )
            }
            return Text(
                "\(used)  downloaded",
                comment: "Downloads storage summary when device capacity is unknown, e.g. 12 GB downloaded"
            )
        }

        private var inProgressLine: Text {
            if split.unfinishedBytes > 0 {
                return Text("\(activeCount) downloads in progress · \(DownloadScreens.byteText(split.unfinishedBytes)) so far")
            }
            return Text("\(activeCount) downloads in progress")
        }

        private var segments: [Segment] {
            [
                Segment(id: 0, label: "Series", bytes: split.seriesBytes, opacity: 1),
                Segment(id: 1, label: "Movies", bytes: split.movieBytes, opacity: 0.52),
                Segment(id: 2, label: "In progress", bytes: split.unfinishedBytes, opacity: 0.34),
                Segment(id: 3, label: "Other", bytes: split.otherBytes, opacity: 0.18),
            ]
        }

        /// Every block is always drawn, so the gaps are always there.
        private var bar: some View {
            let total = Double(split.allBytes)
            return GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(Color.vividOnSurface.opacity(segment.opacity))
                            .frame(width: max(0, geometry.size.width * Double(segment.bytes) / total))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
        }

        private var legend: some View {
            HStack(spacing: 16) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .circular)
                            .fill(Color.vividOnSurface.opacity(segment.opacity))
                            .frame(width: 9, height: 9)
                        Text(verbatim: DownloadScreens.byteText(segment.bytes))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                        Text(segment.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                }
            }
        }
    }

    /// Suggests clearing downloads that have been watched.
    struct ReclaimBanner: View {
        let count: Int
        let bytes: Int64
        let action: () -> Void

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
            Button(action: action) {
                HStack(spacing: 12) {
                    ZStack {
                        tile.fill(Color.vividChromeSelectedFill)
                        tile.stroke(Color.vividChromeSelectedBorder, lineWidth: 1)
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free up \(DownloadScreens.byteText(bytes))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                        Text("\(count) items you've finished")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                    Spacer(minLength: 8)
                    Text("Review")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.vividChromeSelectedFill))
                        .overlay(Capsule().stroke(Color.vividChromeSelectedBorder, lineWidth: 1))
                }
                .padding(13)
                .background(Color.clear.vividGlass(in: shape, tint: Color.white.opacity(0.025)))
                .overlay(shape.stroke(Color.vividChromeSelectedBorder, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    /// The list order menu and the row count.
    struct SortControl: View {
        @Binding var order: DownloadListOrder
        let count: Int

        var body: some View {
            HStack {
                Menu {
                    Picker("Sort", selection: $order) {
                        ForEach(DownloadListOrder.allCases) { option in
                            Label(option.title, systemImage: option.iconName)
                                .tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: order.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.vividOnSurface)
                }
                Spacer()
                Text("\(count) items")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.vividOnSurface.opacity(0.38))
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }
}
#endif
