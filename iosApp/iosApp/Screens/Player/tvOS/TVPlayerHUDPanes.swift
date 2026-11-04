#if os(tvOS)
import SwiftUI

// The Info, Stats, Video, Audio and Chapters panes of the Apple TV player
// HUD. The Subtitles pane is in TVPlayerHUDSubtitles.swift.

extension TVPlayerInfoHUD {
    // MARK: - Info

    struct InfoPane: View {
        let viewModel: PlayerViewModel
        @Binding var isAtTop: Bool
        let onMoveToTabs: () -> Void

        private static let topAnchor = "info.top"
        private static let bottomAnchor = "info.bottom"

        var body: some View {
            HUDScrollablePane(
                accessibilityLabel: "Info details",
                // Down pages a long overview to its end and Up comes back to
                // the top, then to the tabs.
                scrollTargetIDs: [Self.topAnchor, Self.bottomAnchor],
                isAtTop: $isAtTop,
                onMoveToTabs: onMoveToTabs
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    HStack(alignment: .top, spacing: 48) {
                        titleColumn
                        if let overview = viewModel.metadata.overview, !overview.isEmpty {
                            PaneColumn("Overview") {
                                Text(overview)
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        streamColumn
                    }
                    Color.clear.frame(height: 0).id(Self.bottomAnchor)
                }
            }
        }

        private var titleColumn: some View {
            PaneColumn("Title") {
                if let series = viewModel.metadata.seriesTitle, !series.isEmpty {
                    Text(series.uppercased())
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(displayTitle)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let episode = viewModel.metadata.episodeTag {
                    Text(episode)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if !metaBits.isEmpty {
                    Text(metaBits.joined(separator: "  ·  "))
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.65))
                        .monospacedDigit()
                }
            }
        }

        private var streamColumn: some View {
            PaneColumn("Stream") {
                if !viewModel.streamBadges.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.streamBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 16, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(
                                    Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.bottom, 4)
                }
                ForEach(streamRows, id: \.0) { row in
                    LabelValueRow(label: row.0, value: row.1)
                }
                if let chapter = currentChapterTitle {
                    LabelValueRow(label: String(localized: "Chapter", comment: "Info row: the chapter playing now"), value: chapter)
                }
            }
        }

        private var displayTitle: String {
            viewModel.metadata.primaryTitle.isEmpty
                ? viewModel.title
                : viewModel.metadata.primaryTitle
        }

        private var metaBits: [String] {
            var bits: [String] = []
            if let year = viewModel.metadata.year { bits.append(String(year)) }
            if viewModel.duration > 0 {
                bits.append(PlayerTimeFormatter.formatRuntime(viewModel.duration))
            }
            return bits
        }

        /// One short route line (engine and delivery) and the playing audio.
        /// The full decision trace and diagnostics stay in Stats and Settings;
        /// this pane answers "what am I watching".
        private var streamRows: [(String, String)] {
            var rows: [(String, String)] = [(String(localized: "Route", comment: "Info row: the playback engine and route"), viewModel.playbackRouteDisplay)]
            if let audio = viewModel.audioTracks.first(where: { $0.trackId == viewModel.selectedAudioId }) {
                let bits = [PlayerStreamBadges.audioCodec(audio), audio.channelCountLabel].compactMap { $0 }
                if !bits.isEmpty { rows.append((String(localized: "Audio", comment: "Info row: the audio playing now"), bits.joined(separator: " · "))) }
            }
            return rows
        }

        private var currentChapterTitle: String? {
            guard let index = viewModel.currentChapterIndex,
                  viewModel.chapters.indices.contains(index)
            else { return nil }
            let current = viewModel.chapters[index]
            return current.title ?? String(localized: "Chapter \(current.index + 1)", comment: "Fallback name for an untitled chapter")
        }
    }

    // MARK: - Stats

    struct StatsPane: View {
        let viewModel: PlayerViewModel
        @Binding var isAtTop: Bool
        let onMoveToTabs: () -> Void

        private static let topAnchor = "stats.top"
        private static let bottomAnchor = "stats.bottom"

        var body: some View {
            HUDScrollablePane(
                accessibilityLabel: "Playback stats",
                scrollTargetIDs: scrollTargetIDs,
                isAtTop: $isAtTop,
                onMoveToTabs: onMoveToTabs
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    PlaybackStatsPanel(
                        stats: viewModel.playbackStats,
                        usesTVTypography: true,
                        usesThreeColumnLayout: true
                    )
                    Color.clear.frame(height: 0).id(Self.bottomAnchor)
                }
            }
        }

        /// Paging targets. The pane opens at the top (Source and Media), so
        /// the list starts with a top anchor: without it the first Down
        /// skipped a section and Up left for the tabs while Source and Media
        /// were still scrolled off. The bottom anchor reaches the end of a
        /// last section taller than the pane.
        private var scrollTargetIDs: [String] {
            var ids: [String] = [Self.topAnchor]
            if !viewModel.playbackStats.bufferRows.isEmpty {
                ids.append(PlaybackStatsPanel.bufferSectionID)
            }
            if !viewModel.playbackStats.networkRows.isEmpty {
                ids.append(PlaybackStatsPanel.networkSectionID)
            }
            if !viewModel.playbackStats.engineRows.isEmpty {
                ids.append(PlaybackStatsPanel.engineSectionID)
            }
            ids.append(Self.bottomAnchor)
            return ids
        }
    }

    // MARK: - Video

    /// Playback and sync settings. Settings with several options open the
    /// picker; On/Off settings flip in place. Movement between rows and
    /// across the columns is native.
    struct VideoPane: View {
        let viewModel: PlayerViewModel

        @State private var picker = HUDPickerState<Field>()
        @FocusState private var focusedField: Field?

        /// The picker rows, so focus can go back to one when its picker closes.
        private enum Field: Hashable {
            case quality
            case speed
            case aspect
            case subtitleDelay
        }

        var body: some View {
            ZStack {
                HStack(alignment: .top, spacing: 48) {
                    PaneColumn("Playback") {
                        VStack(spacing: 2) {
                            qualityRow
                            speedRow
                            if viewModel.backendCapabilities.supportsVideoGravity {
                                aspectRow
                            }
                        }
                    }
                    .focusSection()

                    PaneColumn("Sync") {
                        VStack(spacing: 2) {
                            if viewModel.backendCapabilities.supportsSubtitleDelay {
                                subtitleDelayRow
                            }
                            HUDToggleRow(label: "Auto-play next", isOn: viewModel.settings.autoPlayNextEpisode) {
                                viewModel.settings.setAutoPlayNextEpisode($0)
                            }
                        }
                    }
                    .focusSection()
                }
                .disabled(picker.isPresented)
                .opacity(picker.isPresented ? 0.28 : 1)

                if let presentation = picker.presentation {
                    HUDPickerDialog(presentation, onClose: closePicker)
                }
            }
            .animation(.easeOut(duration: VividTheme.fastDuration), value: picker.presentation?.id)
        }

        private var qualityRow: some View {
            HUDSettingRow(label: "Quality", value: qualityValue) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Quality",
                        options: viewModel.selectableQualityOptions.map {
                            .init(id: $0.id, label: $0.labelWithBitrate, detail: $0.subtitle)
                        },
                        selection: viewModel.selectedQualityChoiceID,
                        onSelect: { viewModel.switchQuality($0) }
                    ),
                    returningTo: .quality
                )
            }
            .focused($focusedField, equals: .quality)
        }

        private var speedRow: some View {
            HUDSettingRow(label: "Speed", value: Self.formattedSpeed(viewModel.settings.playbackSpeed)) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Playback Speed",
                        options: Self.speedOptions,
                        selection: Self.speedID(viewModel.settings.playbackSpeed),
                        onSelect: { value in
                            if let speed = Double(value) {
                                viewModel.setPlaybackSpeed(speed)
                            }
                        }
                    ),
                    returningTo: .speed
                )
            }
            .focused($focusedField, equals: .speed)
        }

        private var aspectRow: some View {
            HUDSettingRow(label: "Aspect", value: viewModel.settings.videoGravity.label) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Aspect",
                        options: Self.aspectOptions,
                        selection: viewModel.settings.videoGravity.rawValue,
                        onSelect: { value in
                            if let gravity = VideoGravity(rawValue: value) {
                                viewModel.setVideoGravity(gravity)
                            }
                        }
                    ),
                    returningTo: .aspect
                )
            }
            .focused($focusedField, equals: .aspect)
        }

        private var subtitleDelayRow: some View {
            HUDSettingRow(
                label: "Subtitle delay",
                value: HUDPickerOptions.delayLabel(viewModel.subtitleDelayMs)
            ) {
                picker.present(
                    HUDPickerPresentation(
                        title: "Subtitle Delay",
                        options: HUDPickerOptions.subtitleDelayOptions(including: viewModel.subtitleDelayMs),
                        selection: String(viewModel.subtitleDelayMs),
                        onSelect: { value in
                            if let ms = Int(value) {
                                viewModel.setSubtitleSyncMilliseconds(ms)
                            }
                        }
                    ),
                    returningTo: .subtitleDelay
                )
            }
            .focused($focusedField, equals: .subtitleDelay)
        }

        private var qualityValue: String {
            if viewModel.isQualitySwitching {
                return String(localized: "Switching...", comment: "Quality row value while the quality changes")
            }
            if let error = viewModel.qualitySwitchError, !error.isEmpty {
                return error
            }
            return viewModel.selectableQualityOptions.first(where: { $0.id == viewModel.selectedQualityChoiceID })?.labelWithBitrate
                ?? ApplePlaybackQuality.displayNameWithBitrate(for: viewModel.selectedQualityChoiceID)
        }

        private func closePicker() {
            if let field = picker.close() {
                focusedField = field
            }
        }

        private static func speedID(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        private static func formattedSpeed(_ value: Double) -> String {
            if value == 1.0 { return String(localized: "1.0×", comment: "Normal playback speed") }
            let number = value.formatted(.number.precision(.fractionLength(2)))
            return String(localized: "\(number)×", comment: "Playback speed multiplier, for example 1.5×")
        }

        private static let speedOptions: [HUDDropdownOption] = [0.75, 1.0, 1.25, 1.5, 2.0]
            .map { HUDDropdownOption(id: VideoPane.speedID($0), label: VideoPane.formattedSpeed($0)) }

        private static let aspectOptions: [HUDDropdownOption] =
            VideoGravity.allCases.map { .init(id: $0.rawValue, label: $0.label) }
    }

    // MARK: - Audio

    struct AudioPane: View {
        let viewModel: PlayerViewModel

        var body: some View {
            HStack(alignment: .top, spacing: 48) {
                PaneColumn("Tracks") {
                    ScrollView(showsIndicators: false) {
                        // Every row stays mounted, so native movement and
                        // keep-visible scrolling share one owner.
                        VStack(spacing: 2) {
                            ForEach(viewModel.audioTracks) { track in
                                HUDTrackRow(
                                    name: track.primaryLabel,
                                    attributes: track.attributesLabel,
                                    isSelected: viewModel.selectedAudioId == track.trackId
                                ) {
                                    viewModel.selectAudio(track)
                                }
                            }
                        }
                    }
                }
                .focusSection()

                PaneColumn("Options") {
                    LabelValueRow(label: String(localized: "Channels", comment: "Audio row: channel layout"), value: selectedTrack?.channelCountLabel ?? "—")
                    LabelValueRow(label: String(localized: "Codec", comment: "Audio row: audio codec"), value: selectedTrack?.codec?.uppercased() ?? "—")
                }
            }
        }

        private var selectedTrack: PlayerTrack? {
            viewModel.audioTracks.first(where: { $0.trackId == viewModel.selectedAudioId })
        }
    }

    // MARK: - Chapters

    struct ChaptersPane: View {
        @FocusState private var focusedChapter: Int?
        let viewModel: PlayerViewModel
        let onSelect: () -> Void

        var body: some View {
            PaneColumn("Chapters") {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(viewModel.chapters.enumerated()), id: \.offset) { index, chapter in
                            HUDChapterRow(
                                number: index + 1,
                                title: chapter.title ?? String(localized: "Chapter \(index + 1)", comment: "Fallback name for an untitled chapter"),
                                time: PlayerTimeFormatter.formatHMS(chapter.time),
                                isCurrent: viewModel.currentChapterIndex == index
                            ) {
                                viewModel.seekTo(seconds: chapter.time)
                                onSelect()
                            }
                            .focused($focusedChapter, equals: index)
                        }
                    }
                }
            }
            .focusSection()
            .defaultFocus($focusedChapter, viewModel.currentChapterIndex ?? 0, priority: .userInitiated)
        }
    }

    private struct HUDChapterRow: View {
        let number: Int
        let title: String
        let time: String
        let isCurrent: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HUDChapterRowLabel(number: number, title: title, time: time, isCurrent: isCurrent)
            }
            .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
            .accessibilityLabel(title)
            .accessibilityValue(isCurrent ? "Currently playing" : "")
        }
    }

    private struct HUDChapterRowLabel: View {
        let number: Int
        let title: String
        let time: String
        let isCurrent: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: 16) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)

                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isFocused ? .black.opacity(0.8) : .white.opacity(0.8))
                }

                Text(time)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isFocused ? .black.opacity(0.65) : .white.opacity(0.65))
                    .monospacedDigit()
            }
        }
    }
}
#endif
