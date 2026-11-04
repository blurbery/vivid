#if os(iOS)
import SwiftUI

/// The Quality, Audio, Subtitles and Chapters buttons and their popovers.
/// Each popover scrolls, and an open one holds the controls up.
extension MobilePlayerControls {
    /// Round glass buttons above the video, or equal rounded squares across
    /// the half-folded deck.
    func actionRow(asTiles: Bool = false) -> some View {
        HStack(spacing: asTiles ? Self.deckSpacing : 8) {
            if !asTiles { Spacer(minLength: 0) }
            Button { activePopover = .quality } label: {
                selectorIcon("slider.horizontal.3", asTile: asTiles)
            }
            .mobilePlayerSelectorStyle(asTile: asTiles)
            .disabled(viewModel.isQualitySwitching)
            .accessibilityLabel("Streaming quality")
            .accessibilityIdentifier("player.quality")
            .popover(isPresented: popoverBinding(.quality), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                qualityPopover
                    .frame(width: 320, height: popoverHeight)
                    .presentationCompactAdaptation(.popover)
            }
            Button { activePopover = .audio } label: {
                selectorIcon("speaker.wave.2", asTile: asTiles)
            }
            .mobilePlayerSelectorStyle(asTile: asTiles)
            .disabled(viewModel.audioTracks.isEmpty)
            .accessibilityLabel("Audio")
            .accessibilityIdentifier("player.audio")
            .popover(isPresented: popoverBinding(.audio), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                TrackSelectionSheet(viewModel: viewModel, scope: .audio) { activePopover = nil }
                    .frame(width: 320, height: popoverHeight)
                    .presentationCompactAdaptation(.popover)
            }
            Button { activePopover = .subtitles } label: {
                selectorIcon("captions.bubble", asTile: asTiles)
            }
            .mobilePlayerSelectorStyle(asTile: asTiles)
            .accessibilityLabel("Subtitles")
            .accessibilityIdentifier("player.subtitles")
            .popover(isPresented: popoverBinding(.subtitles), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                TrackSelectionSheet(viewModel: viewModel, scope: .subtitles) { activePopover = nil }
                    .frame(width: 300, height: popoverHeight)
                    .presentationCompactAdaptation(.popover)
            }
            Button { activePopover = .chapters } label: {
                selectorIcon("list.bullet.rectangle", asTile: asTiles)
            }
            .mobilePlayerSelectorStyle(asTile: asTiles)
            .accessibilityLabel("Chapters")
            .accessibilityIdentifier("player.chapters")
            .popover(isPresented: popoverBinding(.chapters), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                chaptersPopover
                    .frame(width: 300, height: popoverHeight)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var popoverHeight: CGFloat {
        min(420, max(140, viewportSize.height - 160))
    }

    private func popoverBinding(_ popover: PlayerPopover) -> Binding<Bool> {
        Binding(get: { activePopover == popover }, set: { if !$0 { activePopover = nil } })
    }

    @ViewBuilder
    private func selectorIcon(_ symbol: String, asTile: Bool) -> some View {
        let icon = Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
        if asTile {
            icon.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            icon.frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
        }
    }

    private var qualityPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quality")
                .font(.headline)
                .padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.selectableQualityOptions) { option in
                        Button {
                            activePopover = nil
                            viewModel.switchQuality(option.id)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.labelWithBitrate)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let subtitle = option.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.85)
                                    }
                                }
                                Spacer(minLength: 0)
                                if option.id == viewModel.selectedQualityChoiceID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: 44)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.quality." + option.id)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private var chaptersPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters")
                .font(.headline)
                .padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if viewModel.chapters.isEmpty {
                        Text("This media file has no chapters.")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(viewModel.chapters) { chapter in
                            Button {
                                viewModel.seekTo(seconds: chapter.time)
                                activePopover = nil
                            } label: {
                                HStack(spacing: 12) {
                                    Text(Self.chapterName(chapter))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Text(PlayerTimeFormatter.formatHMS(chapter.time))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44)
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }
}
#endif
