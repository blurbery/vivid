#if os(iOS)
import AVFAudio
import SwiftUI

/// Touch-driven overlay used on iOS/iPadOS. Layout (see
/// docs/ios-player-redesign/mockups.html):
/// - Top strip: close, title block (series eyebrow + episode title)
/// - Center: skip back 10s, play/pause, skip forward 10s
/// - Sides: brightness on the left, system volume on the right
/// - Bottom stack: time row (elapsed / status chips / remaining), capsule
///   scrubber with buffered range + intro tint + scrub
///   preview bubble, with separate round Quality, Audio, Subtitles and
///   Chapters controls. Subtitle and chapter lists scroll in native popovers.
///
/// Tapping the video toggles the overlay. While playing, controls dismiss five
/// seconds after interaction; button presses and open menus suspend dismissal.
/// A background tap within 1.5 seconds of the controls appearing keeps them up.
/// Presentation, screen brightness and system volume are owned here;
/// playback state lives on `PlayerViewModel`.
/// Invisible gestures (double-tap skip, hold-2× and pinch)
/// live in `MobilePlayerGestureLayer` underneath this overlay.
struct MobilePlayerControls: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    /// The iPhone Duo half folded like a laptop. The controls then fill the
    /// lower half as a deck that stays up, and the video plays above it.
    var tabletop: DuoTabletop? = nil
    /// An episode's series poster for the half-folded deck's info card.
    @State private var deckSeriesPosterURL: String?

    @State private var activeSheet: PlayerSheet?
    @State private var activePopover: PlayerPopover?
    @State private var viewportSize: CGSize = .zero
    @State private var bottomControlsHeight: CGFloat = 112
    /// Trailing time label mode: remaining ("−12:34") when true, total
    /// duration otherwise. Tap the label to flip — the native player idiom.
    @State private var showsRemainingTime = true
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    /// Floating stats card. Kept here rather than on the view model because
    /// it is purely presentation, and kept outside the `showControls` gate
    /// below so the auto-hide takes the transport away without it.
    @State private var showsStats = false
    @State private var brightness = MobilePlayerBrightness()
    @State private var systemVolume = MobilePlayerSystemVolume()


    var body: some View {
        // NOTE: the .sheet modifier MUST live outside the `showControls` gate.
        // If it's attached to a view that only exists while controls are
        // visible, hiding the controls would tear down the sheet's host and dismiss
        // the sheet mid-interaction — then re-presents it when controls come
        // back, because @State activeSheet survives the rebuild.
        ZStack {
            if let tabletop {
                tabletopDeck(tabletop)
            } else if viewModel.showControls || activePopover != nil {
                // GeometryReader pins the control stack to the player's own
                // bounds. The bars are siblings of the shared player notice in
                // `PlayerView`'s ZStack; inside the player's `.fullScreenCover`
                // a too-wide bar would otherwise stretch that shared layer past
                // the screen and drag the notice off both edges in portrait.
                // Clamping the stack to `proxy.size` keeps every overlay inside
                // the visible frame regardless of how wide a bar wants to be.
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(viewModel.isTimelineScrubbing ? 0.55 : 0.4)
                            .ignoresSafeArea()
                            .onTapGesture { viewModel.backgroundTapped() }

                        centerCluster
                            .opacity(recedingOpacity)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                        levelControls(height: min(176, max(96,
                            proxy.size.height - 2 * (bottomControlsHeight + 20))))
                            .padding(.horizontal, 16)
                            .opacity(recedingOpacity)
                            .allowsHitTesting(!viewModel.isTimelineScrubbing)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                        VStack(spacing: 0) {
                            topStrip(compact: proxy.size.width < proxy.size.height)
                                .opacity(recedingOpacity)
                            Spacer()
                            bottomStack
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    bottomControlsHeight = max(112, $0)
                                }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        // Hug the bottom: the safe-area inset already keeps
                        // the action row clear of the home indicator, so only
                        // a hairline of extra breathing room is needed.
                        .padding(.bottom, 2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeOut(duration: 0.18), value: viewModel.isTimelineScrubbing)
                    }
                }
                .transition(.opacity)
            }
            // Marker metadata can arrive before the stream is ready. Keep
            // skip actions off the loading/buffering screen.
            if !viewModel.isLoading && !viewModel.isBuffering && viewModel.error == nil {
                if viewModel.showIntroSkip {
                    introSkipPill
                }
                if viewModel.showCreditsSkip {
                    creditsSkipPill
                }
            }
            if showsStats {
                MobilePlaybackStatsOverlay(stats: viewModel.playbackStats)
                    .transition(.opacity)
            }
        }
        .environment(\.mobilePlayerControlPressChanged) { pressed in
            viewModel.touchControlPressChanged(pressed)
        }
        .background(MobilePlayerScreenReader { brightness.attach(to: $0) })
        .background {
            MobilePlayerSystemVolumeReader(volume: systemVolume)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in
            brightness.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            brightness.refresh()
            systemVolume.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            systemVolume.refresh()
        }
        .onDisappear { brightness.restore() }
        .animation(.easeOut(duration: 0.18), value: showsStats)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                PlayerSettingsSheet(
                    viewModel: viewModel,
                    sleepTimer: viewModel.sleepTimer,
                    statsOverlayVisible: Binding(
                        get: { showsStats },
                        set: { newValue in
                            showsStats = newValue
                            // Switching it on closes the sheet: the stats are
                            // only useful over the picture they describe.
                            if newValue { activeSheet = nil }
                        }
                    )
                )
                .vividGlassSheet(startsTall: true, overVideo: true)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .onChange(of: activePopover) { _, value in
            if value != nil { viewModel.pinControlsVisible() }
            else { viewModel.resumeAutoHide() }
        }
        .onChange(of: activeSheet) { _, newValue in
            // Keep controls pinned while a sheet is up, and restart the
            // auto-hide timer once it closes.
            if newValue != nil {
                viewModel.pinControlsVisible()
            } else {
                viewModel.resumeAutoHide()
            }
        }
    }

    /// Top strip, center cluster and action row fade out of the way while
    /// the user is scrubbing so the preview bubble owns the screen.
    private var recedingOpacity: Double {
        viewModel.isTimelineScrubbing ? 0.12 : 1
    }

    private func levelControls(height: CGFloat) -> some View {
        HStack {
            MobilePlayerLevelControl(
                title: "Brightness", systemImage: "sun.max.fill",
                value: Binding(get: { brightness.value }, set: { brightness.set($0) }),
                height: height
            )
            .accessibilityIdentifier("player.brightness")

            Spacer(minLength: 0)

            MobilePlayerLevelControl(
                title: "Volume",
                systemImage: systemVolume.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: Binding(
                    get: { systemVolume.value },
                    set: { systemVolume.set($0) }
                ),
                height: height
            )
            .disabled(!systemVolume.canAdjust)
            .accessibilityIdentifier("player.volume")
        }
    }

    // MARK: - Top strip

    private func topStrip(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                closeButton
                if !compact { titleBlock }
                Spacer(minLength: 0)
                externalPlaybackControls
                // The rotation buttons are a sibling overlay that fades with
                // these controls. Reserve its exact width to avoid overlap.
                Color.clear
                    .frame(width: MobilePlayerRotationControls.width,
                           height: MobilePlayerRotationControls.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if compact {
                HStack(spacing: 12) {
                    titleBlock
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
        .accessibilityLabel("Close Player")
        .accessibilityIdentifier("player.close")
    }

    @ViewBuilder
    private var externalPlaybackControls: some View {
        // Keep PiP mounted with the rest of the top controls. AVKit may publish
        // source readiness a run loop later, but that should only affect the
        // enabled state, never make the pill pop in after the user's tap.
        let showsPiP = pictureInPicture.isSupported
        if showsPiP || viewModel.supportsExternalPlayback {
            HStack(spacing: 8) {
                if showsPiP {
                    Button { pictureInPicture.toggle() } label: {
                        Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
                    }
                    .buttonStyle(MobilePlayerGlassButtonStyle())
                    .disabled(
                        !pictureInPicture.hasSource
                            || (!pictureInPicture.isPossible && !pictureInPicture.isActive)
                    )
                    .accessibilityLabel(pictureInPicture.isActive ? "Stop Picture in Picture" : "Start Picture in Picture")
                }
                if viewModel.supportsExternalPlayback {
                    AirPlayRoutePicker { isPresentingRoutes in
                        if isPresentingRoutes { viewModel.pinControlsVisible() }
                        else { viewModel.resumeAutoHide() }
                    }
                    .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
                    .vividPlayerGlass(in: Circle(), interactive: true)
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let eyebrow = titleEyebrow {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(heroTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
        .layoutPriority(-1)
    }

    /// "SEVERANCE · S2:E4"-style context line. Series title + episode tag
    /// for episodes, release year for movies, nothing when metadata hasn't
    /// resolved yet.
    private var titleEyebrow: String? {
        let metadata = viewModel.metadata
        var parts: [String] = []
        if let series = metadata.seriesTitle, !series.isEmpty {
            parts.append(series)
        }
        if let tag = metadata.episodeTag, !tag.isEmpty {
            parts.append(tag)
        }
        if parts.isEmpty, let year = metadata.year {
            parts.append(String(year))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ").uppercased()
    }

    private var heroTitle: String {
        let primary = viewModel.metadata.primaryTitle
        return primary.isEmpty ? viewModel.title : primary
    }

    // MARK: - Half-folded deck

    /// Laid out like a laptop's lower half: close, title, PiP and AirPlay;
    /// large back, play/pause and forward tiles; the scrubber; then the
    /// Quality, Audio, Subtitles and Chapters buttons.
    private func tabletopDeck(_ tabletop: DuoTabletop) -> some View {
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
                tabletopTile(systemImage: "gobackward.10", accessibilityLabel: "Skip Back 10 Seconds") {
                    viewModel.skipBackward(10)
                }
                .frame(maxWidth: 150)
                tabletopTile(
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    accessibilityLabel: viewModel.isPlaying ? "Pause" : "Play",
                    isPrimary: true
                ) {
                    viewModel.togglePlayPause()
                }
                tabletopTile(systemImage: "goforward.10", accessibilityLabel: "Skip Forward 10 Seconds") {
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

    /// Episodes show their series' poster, from the series page's cached
    /// details when there are some.
    private func loadDeckSeriesPoster() async {
        deckSeriesPosterURL = nil
        guard let seriesId = viewModel.currentWatchDetail?.seriesId, !seriesId.isEmpty else { return }
        let key = CacheKey.itemDetail(seriesId)
        let cached: ItemDetail? = ResponseCache.shared.get(key)
        let detail: ItemDetail?
        if let cached {
            detail = cached
        } else {
            detail = try? await VividAPI.shared.itemDetail(contentId: seriesId)
        }
        guard !Task.isCancelled, let poster = detail?.posterUrl, !poster.isEmpty else { return }
        deckSeriesPosterURL = poster
    }

    private static let deckSquareSize: CGFloat = 56
    private static let deckSpacing: CGFloat = 10
    /// Two squares and the gap between them.
    private static let deckInfoHeight: CGFloat = 2 * deckSquareSize + deckSpacing
    /// Close on the left and PiP over AirPlay on the right, either side of
    /// the info card.
    private static let deckSideWidth: CGFloat = 96

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
                    if let first = synopses.last {
                        deckSynopsisText(first).lineLimit(5)
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

    /// The synopsis, then shorter versions of it made of its first whole
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
                AirPlayRoutePicker { isPresentingRoutes in
                    if isPresentingRoutes { viewModel.pinControlsVisible() }
                    else { viewModel.resumeAutoHide() }
                }
                .frame(width: Self.deckSideWidth, height: Self.deckSquareSize)
                .vividPlayerGlass(in: MobilePlayerTileButtonStyle.shape, interactive: true)
            } else {
                deckSquare(systemImage: "airplayvideo", accessibilityLabel: "AirPlay", width: Self.deckSideWidth) {}
                    .disabled(true)
            }
        }
    }

    private func tabletopTile(
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

    // MARK: - Center

    /// Every circle matches the detail page's 44pt close/remote controls.
    /// Play/pause keeps its white tint without becoming a larger disc.
    private var centerCluster: some View {
        HStack(spacing: 36) {
            Button {
                viewModel.skipBackward(10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle())
            .accessibilityLabel("Skip Back 10 Seconds")

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    // play.fill reads left-heavy inside a circle;
                    // nudge it toward the optical center.
                    .offset(x: viewModel.isPlaying ? 0 : 1.5)
                    .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle(tint: .white.opacity(0.9)))
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.skipForward(10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle())
            .accessibilityLabel("Skip Forward 10 Seconds")
        }
    }

    // MARK: - Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 10) {
            actionRow()
                .opacity(recedingOpacity)
            PlayerTickIsolated { progressSlider }
            PlayerTickIsolated { timeRow }
        }
    }

    private var timeRow: some View {
        HStack {
            Image(systemName: "pause.fill")
                .font(.caption).foregroundStyle(.white)
                .opacity(viewModel.isPlaying ? 0 : 1)
            Text(PlayerTimeFormatter.formatHMS(displayTime))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()

            Spacer()

            if viewModel.sleepTimer.isActive {
                statusChip(
                    systemImage: "moon.zzz.fill",
                    text: PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds)
                )
            }

            Spacer()

            Button {
                showsRemainingTime.toggle()
            } label: {
                Text(trailingTimeText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsRemainingTime ? "Time Remaining" : "Duration")
            .accessibilityHint("Switches between time remaining and total duration")
        }
    }

    private var trailingTimeText: String {
        if showsRemainingTime {
            let remaining = PlayerTimeFormatter.formatHMS(max(viewModel.duration - displayTime, 0))
            return String(localized: "\(remaining) left", comment: "Time remaining in the title, for example 1:02:03 left")
        }
        return PlayerTimeFormatter.formatHMS(viewModel.duration)
    }

    private func statusChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
    }

    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    // MARK: - Scrubber

    private var progressSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.duration > 0
                ? min(max(displayTime / viewModel.duration, 0), 1)
                : 0
            let barHeight: CGFloat = viewModel.isScrubbing ? 12 : 6

            ZStack(alignment: .leading) {
                // Base track
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // Buffered range from Vivid telemetry. Routes that cannot
                // report a comparable value leave the layer empty.
                if let buffered = bufferedFraction, buffered > progress {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(width * buffered, barHeight), height: barHeight)
                }

                introMarker(width: width, height: barHeight)

                // Played portion. Thumbless — the whole bar is the handle.
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(width * progress, barHeight), height: barHeight)
                    .shadow(color: .white.opacity(viewModel.isScrubbing ? 0.35 : 0), radius: 8)
            }
            .frame(height: 20, alignment: .center)
            .animation(.snappy(duration: 0.22), value: viewModel.isScrubbing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        if viewModel.isScrubbing {
                            viewModel.updateScrub(fraction: fraction)
                        } else {
                            viewModel.beginScrub(fraction: fraction)
                        }
                    }
                    .onEnded { _ in
                        viewModel.endScrub()
                    }
            )
            .overlay(alignment: .topLeading) {
                if viewModel.isScrubbing {
                    let previewInset: CGFloat = viewModel.scrubPreviewImage == nil ? 80 : 102
                    scrubPreviewBubble
                        .position(
                            x: min(
                                max(width * progress, previewInset),
                                max(width - previewInset, previewInset)
                            ),
                            y: viewModel.scrubPreviewImage == nil ? -36 : -92
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // The custom scrubber is drag-only; expose it to VoiceOver as an
            // adjustable element that seeks through the same skip path.
            .accessibilityElement()
            .accessibilityLabel("Playback Position")
            .accessibilityValue(
                "\(PlayerTimeFormatter.formatHMS(displayTime)) of \(PlayerTimeFormatter.formatHMS(viewModel.duration))"
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.skipForward(10)
                case .decrement: viewModel.skipBackward(10)
                @unknown default: break
                }
            }
        }
        .frame(height: 20)
    }

    private var bufferedFraction: Double? {
        guard viewModel.duration > 0, viewModel.bufferedAheadSeconds > 0 else { return nil }
        let end = (viewModel.currentTime + viewModel.bufferedAheadSeconds) / viewModel.duration
        return min(max(end, 0), 1)
    }

    /// Floating time + chapter readout pinned above the touch point while
    /// scrubbing. Presentation-only: reads the same `scrubPreviewTime` the
    /// seek machinery already maintains.
    private var scrubPreviewBubble: some View {
        VStack(spacing: 6) {
            if let image = viewModel.scrubPreviewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 176, height: 99)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Text(PlayerTimeFormatter.formatHMS(viewModel.scrubPreviewTime))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            if let chapter = chapterTitle(at: viewModel.scrubPreviewTime) {
                Text(chapter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
        .padding(7)
        .vividPlayerGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize()
    }

    private func chapterTitle(at time: Double) -> String? {
        guard let chapter = viewModel.chapters.last(where: { $0.time <= time }) else { return nil }
        return chapter.title ?? String(localized: "Chapter \(chapter.index + 1)", comment: "Fallback name for an untitled chapter")
    }

    @ViewBuilder
    private func introMarker(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(viewModel.openingSkipRanges.enumerated()), id: \.offset) { _, introRange in
            if viewModel.duration > 0 {
            let start = min(max(introRange.start / viewModel.duration, 0), 1)
            let end = min(max(introRange.end / viewModel.duration, 0), 1)
            if end > start {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.4))
                    .frame(width: width * (end - start), height: height)
                    .offset(x: width * start)
            }
        }
        }
    }

    // MARK: - Action row

    /// Round buttons above the video; equal rounded squares across the
    /// half-folded deck.
    private func actionRow(asTiles: Bool = false) -> some View {
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
                                    Text(chapter.title ?? String(localized: "Chapter \(chapter.index + 1)", comment: "Fallback name for an untitled chapter"))
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

    @ViewBuilder
    private func selectorIcon(_ symbol: String, asTile: Bool = false) -> some View {
        let icon = Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
        if asTile {
            icon.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            icon.frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
        }
    }



    // MARK: - Intro skip

    /// One prominent pill that covers both intro states: "Skip Intro" while
    /// the range is active, "Skip Intro · N" with a cancel circle beside it
    /// once the auto-skip countdown is armed.
    private var introSkipPill: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    if viewModel.introAutoSkipCountdownSeconds != nil {
                        Button {
                            viewModel.cancelIntroAutoSkip()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
                        }
                        .buttonStyle(MobilePlayerGlassButtonStyle())
                        .accessibilityLabel(viewModel.introSkipCancelLabel)
                    }

                    Button {
                        viewModel.skipIntro()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.end.fill")
                            Text(viewModel.introSkipLabel)
                            if let countdown = viewModel.introAutoSkipCountdownSeconds {
                                Text("· \(countdown)")
                                    .opacity(0.55)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: VividTheme.topBarIconHitSize)
                    }
                    .buttonStyle(MobilePlayerGlassButtonStyle())
                    .accessibilityLabel(
                        viewModel.introAutoSkipCountdownSeconds == nil ? viewModel.introSkipLabel : viewModel.introSkipNowLabel
                    )
                }
            }
            .padding(.horizontal, 24)
            // Reserve the same control clearance whether chrome is visible or hidden.
            .padding(.bottom, skipPillClearance)
        }
        .duoTabletopTopHalf(tabletop)
        .transition(.opacity)
    }

    private var creditsSkipPill: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    viewModel.skipCredits()
                } label: {
                    Label("Skip Credits", systemImage: "forward.end.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: VividTheme.topBarIconHitSize)
                }
                .buttonStyle(MobilePlayerGlassButtonStyle())
                .accessibilityLabel("Skip Credits")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, skipPillClearance)
        }
        .duoTabletopTopHalf(tabletop)
        .transition(.opacity)
    }

    /// Half folded, the skip pills sit at the foot of the video instead.
    private var skipPillClearance: CGFloat {
        tabletop == nil ? bottomControlsHeight + 24 : 16
    }

    // MARK: - Sheet identifier

    private enum PlayerPopover { case quality, audio, subtitles, chapters }

    private enum PlayerSheet: Identifiable {
        case settings
        var id: Self { self }
    }
}

/// Match detail chrome without the extra padding added by native glass
/// button styles. A 44pt square is circular; longer labels form a 44pt pill.
private struct MobilePlayerControlPressKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var mobilePlayerControlPressChanged: (Bool) -> Void {
        get { self[MobilePlayerControlPressKey.self] }
        set { self[MobilePlayerControlPressKey.self] = newValue }
    }
}

struct MobilePlayerGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.mobilePlayerControlPressChanged) private var controlPressChanged

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: VividTheme.topBarIconHitSize)
            .frame(height: VividTheme.topBarIconHitSize)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .vividPlayerGlass(in: Capsule(), tint: tint, interactive: true)
            .onChange(of: configuration.isPressed) { _, pressed in controlPressChanged(pressed) }
            .onDisappear { if configuration.isPressed { controlPressChanged(false) } }
    }
}

/// Large rounded tile for the half-folded deck, in the same glass as the
/// round player buttons.
struct MobilePlayerTileButtonStyle: ButtonStyle {
    static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    var tint: Color? = nil
    @Environment(\.mobilePlayerControlPressChanged) private var controlPressChanged
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Self.shape
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(shape)
            .vividPlayerGlass(in: shape, tint: tint, interactive: true)
            .onChange(of: configuration.isPressed) { _, pressed in controlPressChanged(pressed) }
            .onDisappear { if configuration.isPressed { controlPressChanged(false) } }
    }
}

extension View {
    /// Round glass button above the video, or a rounded square in the deck.
    @ViewBuilder
    func mobilePlayerSelectorStyle(asTile: Bool) -> some View {
        if asTile {
            buttonStyle(MobilePlayerTileButtonStyle())
        } else {
            buttonStyle(MobilePlayerGlassButtonStyle())
        }
    }
}

/// Close and rotation controls share the same visibility, hit testing and
/// accessibility state, including while loading and on Next Up.
struct MobilePlayerChromeVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            // Transport, PiP, rotate and lock must appear in the same frame.
            // A separate implicit animation here made the detached top-right
            // overlay visibly trail the main controls after a tap.
            .transaction { transaction in transaction.animation = nil }
    }
}

/// Top-right chrome follows transport visibility in every playback phase.
/// Equal tap areas keep the lock centred through rotation.
struct MobilePlayerRotationControls: View {
    static let height = VividTheme.topBarIconHitSize
    static let width = height * 2 + 8
    static let topClearance: CGFloat = height + 32

    let orientationCoordinator: PlayerOrientationCoordinator
    let isVisible: Bool
    var onInteraction: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                orientationCoordinator.togglePlayerOrientation()
                onInteraction()
            } label: {
                icon("rectangle.landscape.rotate")
            }
            .accessibilityLabel(orientationCoordinator.nextPlayerOrientation.rotateAccessibilityLabel)
            .accessibilityHint("Rotates the screen without interrupting playback")
            .accessibilityIdentifier("player.rotate")

            Button {
                orientationCoordinator.toggleRotationLock()
                onInteraction()
            } label: {
                icon(orientationCoordinator.isRotationLocked ? "lock" : "lock.open")
            }
            .accessibilityLabel(orientationCoordinator.isRotationLocked ? "Unlock screen rotation" : "Lock screen rotation")
            .accessibilityValue(orientationCoordinator.isRotationLocked ? "Locked" : "Unlocked")
            .accessibilityHint(orientationCoordinator.isRotationLocked
                ? "Allows video to follow phone orientation"
                : "Stops phone movement rotating video. The rotate button still works")
            .accessibilityIdentifier("player.rotation-lock")
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
        .modifier(MobilePlayerChromeVisibility(isVisible: isVisible))
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            .contentShape(Rectangle())
    }
}
#endif
