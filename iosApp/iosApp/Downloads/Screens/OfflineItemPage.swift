#if os(iOS)
import SwiftUI

/// One downloaded movie or episode: play or resume it, see what was saved,
/// or delete it.
struct OfflineDownloadDetailView: View {
    let downloadId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: OfflineManifest?

    init(downloadId: String) {
        self.downloadId = downloadId
    }

    private var manager: DownloadManager { .shared }

    var body: some View {
        Group {
            if let record = manager.record(withId: downloadId) {
                content(record)
            } else {
                EmptyStateView(icon: "arrow.down.circle", title: "Download Removed")
            }
        }
        .vividPageBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        .task {
            // Read each time the page appears until a read succeeds.
            guard manifest == nil, let record = manager.record(withId: downloadId) else { return }
            manifest = await manager.readManifest(for: record)
        }
    }

    private func content(_ record: DownloadRecord) -> some View {
        let fraction = resumeFraction(record)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                artworkPanel(record, fraction: fraction)
                VStack(alignment: .leading, spacing: 0) {
                    if record.type == "episode" {
                        Text(verbatim: eyebrow(record))
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(Color.vividSecondaryText)
                            .padding(.bottom, 5)
                    }
                    Text(verbatim: record.title ?? record.contentId)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.vividOnSurface)
                    Text(verbatim: metaLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.vividSecondaryText)
                        .padding(.top, 4)
                    DownloadScreens.AvailabilityChip(text: availability(record))
                        .padding(.top, 13)
                    playRow(record, fraction: fraction)
                        .padding(.top, 14)
                    if let overview = manifest?.overview, !overview.isEmpty {
                        Text(verbatim: overview)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineSpacing(2)
                            .padding(.top, 16)
                    }
                    facts(record)
                        .padding(.top, 16)
                    deleteButton(record)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Color.clear
                    .frame(height: 30)
            }
        }
    }

    // MARK: Parts

    private func artworkPanel(_ record: DownloadRecord, fraction: Double?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            DownloadScreens.play(record, router: router)
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .overlay(alignment: .bottom) {
                    if let fraction {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.vividOnSurface.opacity(0.22))
                                Rectangle()
                                    .fill(Color.vividOnSurface)
                                    .frame(width: geometry.size.width * fraction)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .downloadGlassCard(cornerRadius: 20)
                .clipShape(shape)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func playRow(_ record: DownloadRecord, fraction: Double?) -> some View {
        let position = manager.savedProgress(for: record.leafMediaItemId)?.position ?? 0
        let title = position > 30
            ? String(localized: "Resume \(PlayerTimeFormatter.formatHMS(position))", comment: "Button that resumes from a time, e.g. Resume 1:02:30")
            : String(localized: "Play")
        let restartShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 11) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: title,
                action: { DownloadScreens.play(record, router: router) },
                fullWidth: true
            )
            if fraction != nil {
                Button {
                    guard record.isPlayableOffline else { return }
                    router.presentOfflinePlayer(
                        downloadId: record.id,
                        contentId: record.leafMediaItemId,
                        resumePosition: 0
                    )
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .frame(width: 52, height: 52)
                        .background(restartShape.fill(Color.vividChromeRestingFill))
                        .overlay(restartShape.stroke(Color.vividChromeRestingBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart from beginning")
            }
        }
    }

    private func facts(_ record: DownloadRecord) -> some View {
        VStack(spacing: 0) {
            if let audio = manifest?.codecAudio, !audio.isEmpty {
                factRow("Audio", value: audio.uppercased())
            }
            factRow("Quality", value: qualityFact(record))
            if let date = record.downloadedAt {
                factRow("Downloaded", value: date.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .overlay(alignment: .top) {
            Divider()
                .overlay(Color.vividDivider)
        }
    }

    @ViewBuilder
    private func factRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.vividSecondaryText)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.vividOnSurface)
        }
        .padding(.vertical, 11)
        Divider()
            .overlay(Color.vividDivider)
    }

    private func deleteButton(_ record: DownloadRecord) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button {
            manager.remove(recordId: record.id)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Delete download · Free \(DownloadScreens.byteText(record.fileSize))")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Color.vividError)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(Color.vividChromeRestingFill))
            .overlay(shape.stroke(Color.vividChromeRestingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Text

    /// How far through, when it's more than 30 seconds in and not nearly
    /// finished.
    private func resumeFraction(_ record: DownloadRecord) -> Double? {
        guard let progress = manager.savedProgress(for: record.leafMediaItemId),
              progress.position > 30, progress.duration > 0 else { return nil }
        let fraction = min(max(progress.position / progress.duration, 0), 1)
        return fraction >= 0.98 ? nil : fraction
    }

    /// "SEVERANCE · S1 · E4".
    private func eyebrow(_ record: DownloadRecord) -> String {
        let series = (record.seriesTitle ?? manifest?.seriesTitle ?? "").uppercased()
        let tag = [
            record.seasonNumber.map {
                String(localized: "S\(String($0))", comment: "Season number abbreviation, e.g. S1")
            },
            record.episodeNumber.map {
                String(localized: "E\(String($0))", comment: "Episode number abbreviation, e.g. E4")
            },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return [series, tag].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var metaLine: String {
        var parts: [String] = []
        if let runtime = manifest?.runtime, runtime > 0 {
            parts.append(String(localized: "\(runtime) min"))
        }
        if let year = manifest?.year {
            parts.append(String(year))
        }
        return parts.joined(separator: " · ")
    }

    private func availability(_ record: DownloadRecord) -> String {
        var parts = [String(localized: "Downloaded"), DownloadScreens.byteText(record.fileSize)]
        if let resolution = manifest?.resolution, !resolution.isEmpty {
            parts.append(resolution)
        }
        return parts.joined(separator: " · ")
    }

    /// Resolution, codec, HDR, the quality and how the file was made.
    private func qualityFact(_ record: DownloadRecord) -> String {
        var parts: [String] = []
        if let resolution = manifest?.resolution, !resolution.isEmpty {
            parts.append(resolution)
        }
        if let codec = manifest?.codecVideo, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if manifest?.hdr == true {
            parts.append("HDR")
        }
        let quality = manifest?.effectiveQuality ?? record.effectiveQuality ?? record.format
        parts.append(DownloadFormat(rawValue: quality)?.displayName ?? quality.capitalized)
        let delivery = manifest?.deliveryFormat ?? record.deliveryFormat ?? ""
        if !delivery.isEmpty, delivery != "original" {
            switch delivery {
            case "remux": parts.append(String(localized: "Remux"))
            case "transcode": parts.append(String(localized: "Transcode"))
            default: parts.append(delivery.capitalized)
            }
        }
        return parts.joined(separator: " · ")
    }
}
#endif
