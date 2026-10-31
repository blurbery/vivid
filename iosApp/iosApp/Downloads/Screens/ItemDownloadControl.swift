#if os(iOS)
import SwiftUI

/// The download button on a movie page (and on an episode page without a
/// series). It shows the download's state live, and every download starts
/// from the options sheet.
struct DownloadActionButton: View {
    enum Style {
        case labeled
    }

    private let contentId: String
    private let isEpisode: Bool
    private let seriesId: String?
    private let displayTitle: String
    private let displaySubtitle: String?
    private let year: Int?
    private let posterThumbhash: String?
    private let versions: [FileVersion]
    private let selectedVersionFileId: Int?
    private let lastVersionFileId: Int?
    private let style: Style
    @Binding private var showOptions: Bool

    @Environment(\.phoneDetailActionsShareRow) private var sharesActionRow
    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @State private var showsUnavailable = false
    @State private var showsCancelConfirmation = false
    @State private var caption: String?
    @State private var startedCount = 0
    @State private var failedCount = 0

    init(
        detail: ItemDetail,
        versions: [FileVersion],
        selectedVersionFileId: Int?,
        showOptions: Binding<Bool>,
        style: Style = .labeled
    ) {
        contentId = detail.contentId
        isEpisode = detail.type == "episode"
        seriesId = detail.seriesId
        displayTitle = detail.title
        displaySubtitle = DownloadScreens.episodeTag(
            season: detail.seasonNumber,
            episode: detail.episodeNumber,
            fallback: detail.seriesTitle
        )
        year = detail.year
        posterThumbhash = detail.posterThumbhash
        self.versions = versions
        self.selectedVersionFileId = selectedVersionFileId
        lastVersionFileId = detail.userData?.lastFileId
        self.style = style
        _showOptions = showOptions
    }

    private var manager: DownloadManager { .shared }

    private var metrics: PhoneLabeledActionMetrics {
        PhoneLabeledActionMetrics(sharesRow: sharesActionRow, tvStyle: usesTVStyle)
    }

    var body: some View {
        control
            .overlay(alignment: .top) { startCaption }
            .sensoryFeedback(.success, trigger: startedCount)
            .sensoryFeedback(.error, trigger: failedCount)
            .modifier(DownloadScreens.UnavailableAlert(isPresented: $showsUnavailable))
            .confirmationDialog(cancelTitle, isPresented: $showsCancelConfirmation, titleVisibility: .visible) {
                Button("Discard Download", role: .destructive) {
                    if let record { manager.remove(recordId: record.id) }
                }
                Button("Keep Download", role: .cancel) {}
            }
            .sheet(isPresented: $showOptions) {
                DownloadScreens.OptionsSheet(
                    title: displayTitle,
                    versions: versions,
                    selectedVersionFileId: selectedVersionFileId,
                    lastVersionFileId: lastVersionFileId,
                    isEpisode: isEpisode,
                    onStart: startDownload
                )
            }
    }

    // MARK: State

    private var record: DownloadRecord? { manager.record(forContentId: contentId) }

    private var isRegistering: Bool {
        manager.hasPendingRequest(contentId: contentId) && record == nil
    }

    private var isOffForAccount: Bool {
        record == nil && manager.downloadsOffForAccount
    }

    // MARK: Control

    @ViewBuilder
    private var control: some View {
        if isRegistering {
            labelled(glyph: spinner, active: true, caption: String(localized: "Preparing"), captionColour: .white.opacity(0.6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Registering download")
        } else if isOffForAccount {
            Button {
                showsUnavailable = true
            } label: {
                labelled(glyph: DownloadScreens.CrossedOutGlyph(size: 19), active: false,
                         caption: String(localized: "Unavailable"), captionColour: .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download unavailable")
            .accessibilityHint("Downloads aren't enabled for this account")
        } else if let record {
            recordControl(record)
        } else {
            Button(action: downloadTapped) {
                labelled(glyph: symbol("arrow.down.to.line", colour: .white), active: false,
                         caption: String(localized: "Download"), captionColour: .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Download Options…", systemImage: "slider.horizontal.3") { showOptions = true }
            }
            .accessibilityLabel("Download")
        }
    }

    @ViewBuilder
    private func recordControl(_ record: DownloadRecord) -> some View {
        switch record.localStatus {
        case .downloading, .paused:
            let paused = record.localStatus == .paused
            Menu {
                if paused {
                    Button("Resume", systemImage: "play") { manager.resumeTransfer(recordId: record.id) }
                } else {
                    Button("Pause", systemImage: "pause") { manager.pauseTransfer(recordId: record.id) }
                }
                cancelItem
            } label: {
                labelled(glyph: ring(fraction: record.progressFraction, paused: paused), active: true,
                         caption: paused ? String(localized: "Paused") : String(localized: "Downloading"),
                         captionColour: .white.opacity(0.85))
            }
            .accessibilityLabel(paused ? Text("Download paused") : Text("Downloading"))
            .accessibilityValue(Text(verbatim: String(localized: "\(Self.percent(record.progressFraction)) percent")))
        case .registering, .preparing, .queued, .fetchingAssets, .waiting:
            Menu {
                cancelItem
            } label: {
                labelled(glyph: spinner, active: true,
                         caption: String(localized: "Preparing"), captionColour: .white.opacity(0.85))
            }
            .accessibilityLabel("Preparing download")
        case .completed, .revoked:
            let revoked = record.localStatus == .revoked
            Menu {
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    manager.remove(recordId: record.id)
                }
            } label: {
                labelled(
                    glyph: revoked
                        ? symbol("checkmark.circle", colour: .yellow)
                        : symbol("checkmark.circle.fill", colour: .green),
                    active: true,
                    caption: String(localized: "Downloaded"),
                    captionColour: .green.opacity(0.9)
                )
            }
            .accessibilityLabel(revoked ? Text("Downloaded (re-download no longer allowed)") : Text("Downloaded"))
        case .failed:
            Menu {
                Button("Retry With Options", systemImage: "arrow.clockwise") { showOptions = true }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    manager.remove(recordId: record.id)
                }
            } label: {
                labelled(glyph: symbol("exclamationmark.triangle", colour: .orange), active: true,
                         caption: String(localized: "Failed"), captionColour: .orange.opacity(0.9))
            }
            .accessibilityLabel("Download failed")
        }
    }

    private var cancelItem: some View {
        Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) {
            showsCancelConfirmation = true
        }
    }

    private var cancelTitle: String {
        let downloaded = record?.bytesDownloaded ?? 0
        guard downloaded > 0 else { return String(localized: "Cancel this download?") }
        let size = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        return String(localized: "Discard \(size) of downloaded data?")
    }

    // MARK: Drawing

    /// The glyph in its circle, with the caption under it when the layout
    /// shows captions.
    private func labelled<Glyph: View>(glyph: Glyph, active: Bool, caption: String, captionColour: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(active ? 0.18 : 0.10))
                glyph
            }
            .frame(width: metrics.circle, height: metrics.circle)
            if metrics.showsCaption {
                Text(verbatim: caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(captionColour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: sharesActionRow, vertical: false)
            }
        }
        .frame(width: metrics.slotWidth)
        .frame(maxWidth: metrics.slotWidth == nil ? .infinity : nil, minHeight: metrics.minHeight)
        .contentShape(Rectangle())
    }

    private func symbol(_ name: String, colour: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(colour)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
    }

    private var spinner: some View {
        ZStack {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
            DownloadScreens.ActivityArc(diameter: 27, lineWidth: 2)
        }
    }

    private func ring(fraction: Double, paused: Bool) -> some View {
        ZStack {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                    .stroke(paused ? Color.white.opacity(0.55) : Color.white,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if paused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                } else {
                    Text("\(Self.percent(fraction))")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 21, height: 21)
            if !paused {
                DownloadScreens.ActivityArc(diameter: 27, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var startCaption: some View {
        if let caption {
            Text(verbatim: caption)
                .font(.vividCaption)
                .foregroundStyle(Color.vividOnSurface)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .fixedSize()
                .offset(y: -36)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    // MARK: Actions

    private func downloadTapped() {
        guard !manager.hasPendingRequest(contentId: contentId), record == nil else { return }
        guard manager.hasDownloadAnswer, !manager.hasFailedCheck else {
            let serverId = ServerRegistry.shared.activeServerId
            Task { @MainActor in
                let ready = await manager.prepareForDownload()
                guard ServerRegistry.shared.activeServerId == serverId else { return }
                guard ready else {
                    if manager.downloadsOffForAccount {
                        showsUnavailable = true
                    } else {
                        announceFailure()
                    }
                    return
                }
                downloadTapped()
            }
            return
        }
        showOptions = true
    }

    private func startDownload(fileId: Int?, quality: String) {
        Task { @MainActor in
            do {
                if isEpisode {
                    try await manager.downloadEpisode(
                        seriesId: seriesId ?? contentId,
                        episodeId: contentId,
                        displayTitle: displayTitle,
                        displaySubtitle: displaySubtitle,
                        posterThumbhash: posterThumbhash,
                        fileId: fileId,
                        quality: quality
                    )
                } else {
                    try await manager.requestMovie(
                        contentId: contentId,
                        title: displayTitle,
                        year: year,
                        posterThumbhash: posterThumbhash,
                        fileId: fileId,
                        quality: quality
                    )
                }
                announceStart()
            } catch DownloadError.registrationAlreadyInFlight {
                // The first request owns the in-progress state.
            } catch {
                announceFailure()
            }
        }
    }

    private func announceStart() {
        startedCount += 1
        showCaption(String(localized: "Download started"))
    }

    private func announceFailure() {
        failedCount += 1
        showCaption(String(localized: "Couldn't start download"))
    }

    /// Each caption clears itself after two seconds, so a second one inside
    /// that window goes when the first one's timer fires.
    private func showCaption(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { caption = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeIn(duration: 0.3)) { caption = nil }
        }
    }
}
#endif
