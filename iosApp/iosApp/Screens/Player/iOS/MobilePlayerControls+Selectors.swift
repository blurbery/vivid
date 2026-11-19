#if os(iOS)
import SwiftUI

/// The Quality, Audio, Subtitles, Song and Chapters buttons and their
/// popovers. Each popover scrolls, and an open one holds the controls up.
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
            if showsSongButton {
                Button {
                    activePopover = .song
                    startSongIdentification()
                } label: {
                    selectorIcon("music.note", asTile: asTiles)
                }
                .mobilePlayerSelectorStyle(asTile: asTiles)
                .accessibilityLabel(SongIdentificationText.identify)
                .accessibilityIdentifier("player.song")
                .popover(isPresented: popoverBinding(.song), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    SongIdentificationPopover(model: viewModel.songIdentification)
                        .frame(width: 320, height: popoverHeight)
                        .presentationCompactAdaptation(.popover)
                }
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
        .onChange(of: showsSongButton) { _, shows in
            // The popover goes with its button, and the controls shouldn't
            // stay held up for it.
            if !shows && activePopover == .song { activePopover = nil }
        }
    }

    /// Song identification needs sound. This goes by the load and its
    /// tracks rather than the model's `unavailability`, which reads the
    /// playhead and would redraw all the controls on every tick. While the
    /// item loads the button stays, and the popover says to wait.
    private var showsSongButton: Bool {
        !viewModel.isAudioOnlyVividLoad && (viewModel.isLoading || !viewModel.audioTracks.isEmpty)
    }

    /// The Song button opens its popover and starts listening straight
    /// away, unless it's listening already or showing a song found. The
    /// model does nothing when the item can't be identified, and the
    /// popover says why.
    private func startSongIdentification() {
        let model = viewModel.songIdentification
        switch model.phase {
        case .idle, .notFound, .failed, .refused: model.identify()
        case .listening, .found: break
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

/// The Song popover: what's happening while Shazam listens, then the song
/// found with Save to Shazam, Apple Music and Try again. The Apple TV Song
/// tab says the same things (`SongIdentificationText`).
///
/// Closing the popover doesn't stop listening; the result waits here.
struct SongIdentificationPopover: View {
    let model: SongIdentificationModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        let phase = model.phase
        let blocked = blockedReason
        VStack(alignment: .leading, spacing: 0) {
            Text(SongIdentificationText.title)
                .font(.headline)
                .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    details(phase: phase, blocked: blocked)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    if blocked == nil {
                        Divider()
                        actions(phase: phase)
                    }
                }
            }
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Why the popover offers nothing to press: only reasons that last for
    /// the whole load, which read neither the playhead nor the buffer. A
    /// passing reason shows once the viewer presses (`.refused`).
    private var blockedReason: SongIdentificationModel.Unavailability? {
        if model.isListening { return nil }
        return model.blockingReason
    }

    // MARK: - Details

    @ViewBuilder
    private func details(
        phase: SongIdentificationModel.Phase,
        blocked: SongIdentificationModel.Unavailability?
    ) -> some View {
        if let blocked {
            secondaryText(SongIdentificationText.unavailable(blocked))
        } else {
            switch phase {
            case .idle:
                secondaryText(SongIdentificationText.help)
            case .listening:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(SongIdentificationText.listening)
                        .foregroundStyle(.primary)
                }
            case let .found(match):
                HStack(spacing: 12) {
                    SongArtwork(url: match.artworkURL, size: 64, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        // Shazam's text, shown as it is.
                        Text(match.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let artist = match.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            case .notFound:
                VStack(alignment: .leading, spacing: 4) {
                    Text(SongIdentificationText.notFoundTitle)
                        .font(.headline)
                    secondaryText(SongIdentificationText.notFoundDetail)
                }
            case let .failed(failure):
                secondaryText(SongIdentificationText.failure(failure))
            case let .refused(reason):
                secondaryText(SongIdentificationText.unavailable(reason))
            }
        }
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buttons

    @ViewBuilder
    private func actions(phase: SongIdentificationModel.Phase) -> some View {
        switch phase {
        case .idle:
            actionRow(SongIdentificationText.identify, identifier: "player.song.identify") {
                model.identify()
            }
        case .listening:
            actionRow(SongIdentificationText.stop, identifier: "player.song.stop") {
                model.cancel()
            }
        case let .found(match):
            // Shazam's library only takes songs with a Shazam ID.
            if match.shazamID != nil {
                let saveState = model.saveState
                actionRow(
                    SongIdentificationText.save(saveState),
                    systemImage: saveState == .saved ? "checkmark" : nil,
                    isEnabled: saveState == .idle || saveState == .failed,
                    identifier: "player.song.save"
                ) {
                    model.saveToShazam()
                }
            }
            if let appleMusicURL = match.appleMusicURL {
                actionRow(SongIdentificationText.appleMusic, identifier: "player.song.appleMusic") {
                    openURL(appleMusicURL)
                }
            }
            actionRow(SongIdentificationText.tryAgain, identifier: "player.song.tryAgain") {
                model.identify()
            }
        case .notFound, .failed, .refused:
            actionRow(SongIdentificationText.tryAgain, identifier: "player.song.tryAgain") {
                model.identify()
            }
        }
    }

    /// A row the size of the Quality and Chapters rows, tinted as an action.
    private func actionRow(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(minHeight: 44)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
    }
}
#endif
