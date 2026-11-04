#if os(iOS)
import SwiftUI

/// The control deck on the lower half of an iPhone Duo half folded like a
/// laptop, with the video above the crease.
extension MobilePlayerControls {
    static let deckSquareSize: CGFloat = 56
    static let deckSpacing: CGFloat = 10
    /// Two squares and the gap between them.
    static let deckInfoHeight: CGFloat = 2 * deckSquareSize + deckSpacing
    /// Close on the left, and PiP over AirPlay on the right, either side of
    /// the info card.
    static let deckSideWidth: CGFloat = 96

    /// Close, the info card, PiP and AirPlay; large back, play or pause and
    /// forward tiles; the scrubber and time; then the Quality, Audio,
    /// Subtitles and Chapters tiles.
    func tabletopDeck(_ tabletop: DuoTabletop) -> some View {
        VStack(spacing: 18) {
            // Close, PiP and AirPlay stand as tall as the info card.
            HStack(spacing: Self.deckSpacing) {
                deckSquare(
                    systemImage: "xmark",
                    accessibilityLabel: "Close Player",
                    width: Self.deckSideWidth,
                    height: Self.deckInfoHeight,
                    action: onDismiss
                )
                .accessibilityIdentifier("player.close")
                deckInfoCard
                deckExternalPlaybackColumn
            }
            .frame(height: Self.deckInfoHeight)
            Spacer(minLength: 0)
            HStack(spacing: Self.deckSpacing) {
                transportTile(systemImage: "gobackward.10", accessibilityLabel: "Skip Back 10 Seconds") {
                    viewModel.skipBackward(10)
                }
                .frame(maxWidth: 150)
                transportTile(
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    accessibilityLabel: viewModel.isPlaying ? "Pause" : "Play",
                    isPrimary: true
                ) {
                    viewModel.togglePlayPause()
                }
                transportTile(systemImage: "goforward.10", accessibilityLabel: "Skip Forward 10 Seconds") {
                    viewModel.skipForward(10)
                }
                .frame(maxWidth: 150)
            }
            .frame(height: 84)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                PlayerTickIsolated { progressSlider }
                PlayerTickIsolated { timeRow }
            }
            actionRow(asTiles: true)
                .frame(height: Self.deckSquareSize)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, tabletop.crease.maxY)
        .ignoresSafeArea(edges: .top)
        .transition(.opacity)
        .task(id: viewModel.currentWatchDetail?.seriesId) {
            await loadDeckSeriesPoster()
        }
    }

    /// An episode shows its series' poster, from the series page's cached
    /// details when there are some.
    private func loadDeckSeriesPoster() async {
        deckSeriesPosterURL = nil
        guard let seriesId = viewModel.currentWatchDetail?.seriesId, !seriesId.isEmpty else { return }
        let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
        let detail: ItemDetail?
        if let cached {
            detail = cached
        } else {
            detail = try? await VividAPI.shared.itemDetail(contentId: seriesId)
        }
        guard !Task.isCancelled, let poster = detail?.posterUrl, !poster.isEmpty else { return }
        deckSeriesPosterURL = poster
    }

    private func deckSquare(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        width: CGFloat = deckSquareSize,
        height: CGFloat = deckSquareSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(MobilePlayerTileButtonStyle())
        .frame(width: width, height: height)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What's playing: the poster, the show and episode line with the title,
    /// and the synopsis beside them, over a soft wash of the backdrop.
    private var deckInfoCard: some View {
        let shape = MobilePlayerTileButtonStyle.shape
        let synopses = Self.synopsisCandidates(viewModel.metadata.overview)
        return HStack(alignment: .center, spacing: 12) {
            if let poster = deckPosterURL {
                AsyncImageView(url: poster, contentMode: .fill)
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow = titleEyebrow {
                    Text(eyebrow)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                Text(heroTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .frame(maxWidth: 124, alignment: .leading)
            if !synopses.isEmpty {
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 0.5)
                    .padding(.vertical, 4)
                // The whole synopsis when it fits, otherwise its first
                // sentences, so it ends on a full stop rather than "...".
                ViewThatFits(in: .vertical) {
                    ForEach(synopses, id: \.self) { synopsis in
                        deckSynopsisText(synopsis)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let shortest = synopses.last {
                        deckSynopsisText(shortest).lineLimit(5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if let backdrop = deckBackdropURL {
                AsyncImageView(url: backdrop, contentMode: .fill, placeholderStyle: .clear)
                    .blur(radius: 24)
                    .opacity(0.32)
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.1), .black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityHidden(true)
            }
        }
        .clipShape(shape)
        .vividPlayerGlass(in: shape)
        .accessibilityElement(children: .combine)
    }

    private func deckSynopsisText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.72))
            .lineSpacing(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The synopsis, then shorter versions made of its first whole
    /// sentences, longest first.
    private static func synopsisCandidates(_ overview: String?) -> [String] {
        guard let overview = overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty else { return [] }
        var sentences: [String] = []
        overview.enumerateSubstrings(in: overview.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        guard sentences.count > 1 else { return [overview] }
        return (1...sentences.count).reversed().map { sentences.prefix($0).joined(separator: " ") }
    }

    private var deckPosterURL: String? {
        [deckSeriesPosterURL, viewModel.artworkPosterURLHint, viewModel.artworkBackdropURLHint]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    private var deckBackdropURL: String? {
        [viewModel.artworkBackdropURLHint, viewModel.artworkPosterURLHint]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    /// PiP over AirPlay. Both always show so the deck keeps its shape, and
    /// are dimmed while the device or stream can't use them.
    private var deckExternalPlaybackColumn: some View {
        VStack(spacing: Self.deckSpacing) {
            deckSquare(
                systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                accessibilityLabel: pictureInPicture.isActive ? "Stop Picture in Picture" : "Start Picture in Picture",
                width: Self.deckSideWidth
            ) {
                pictureInPicture.toggle()
            }
            .disabled(
                !pictureInPicture.isSupported
                    || !pictureInPicture.hasSource
                    || (!pictureInPicture.isPossible && !pictureInPicture.isActive)
            )
            if viewModel.supportsExternalPlayback {
                AirPlayRoutePicker(onPresentingRoutes: pinWhilePresentingRoutes)
                    .frame(width: Self.deckSideWidth, height: Self.deckSquareSize)
                    .vividPlayerGlass(in: MobilePlayerTileButtonStyle.shape, interactive: true)
            } else {
                deckSquare(systemImage: "airplayvideo", accessibilityLabel: "AirPlay", width: Self.deckSideWidth) {}
                    .disabled(true)
            }
        }
    }

    private func transportTile(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 30 : 24, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(isPrimary ? Color.black.opacity(0.85) : .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(MobilePlayerTileButtonStyle(tint: isPrimary ? .white.opacity(0.9) : nil))
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif
