#if os(iOS)
import AVFAudio
import SwiftUI

/// The touch controls drawn over the video on iPhone and iPad.
///
/// - Top strip: close, the title block, PiP and AirPlay, and room for the
///   rotation buttons, which `PlayerView` overlays separately.
/// - Centre: skip back 10 seconds, play or pause, skip forward 10 seconds.
/// - Sides: brightness on the left, system volume on the right.
/// - Bottom: the round Quality, Audio, Subtitles and Chapters buttons, the
///   scrubber and the time row.
///
/// Half folded on the iPhone Duo, the same controls become a deck that fills
/// the lower half and stays up (`MobilePlayerControls+Deck.swift`). The
/// selector buttons and their popovers are in `MobilePlayerControls+Selectors.swift`.
///
/// The view model owns visibility: tapping the video toggles the controls,
/// they hide five seconds after the last interaction while playing, and
/// button presses, open popovers and the AirPlay route sheet hold them up. A
/// background tap within 1.5 seconds of the controls appearing keeps them up.
/// This view owns only presentation, screen brightness and system volume.
/// The invisible gestures (double-tap skip, hold for 2x, pinch) live in
/// `MobilePlayerGestureLayer` underneath.
struct MobilePlayerControls: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    /// The iPhone Duo half folded like a laptop. The controls then fill the
    /// lower half as a deck that stays up, and the video plays above it.
    var tabletop: DuoTabletop? = nil

    /// An episode's series poster for the half-folded deck's info card.
    @State var deckSeriesPosterURL: String?
    @State var activePopover: PlayerPopover?
    @State var viewportSize: CGSize = .zero
    @State private var bottomControlsHeight: CGFloat = 112
    /// The trailing time label shows the time left when true and the total
    /// duration otherwise. Tapping the label flips it.
    @State private var showsRemainingTime = true
    @State var pictureInPicture = PictureInPictureCoordinator.shared
    @State private var brightness = MobilePlayerBrightness()
    @State private var systemVolume = MobilePlayerSystemVolume()

    enum PlayerPopover { case quality, audio, subtitles, chapters }

    var body: some View {
        ZStack {
            if let tabletop {
                tabletopDeck(tabletop)
            } else if viewModel.showControls || activePopover != nil {
                overlay
                    .transition(.opacity)
            }
            // Marker metadata can arrive before the stream is ready, so the
            // skip buttons stay off the loading and buffering screens.
            if !viewModel.isLoading && !viewModel.isBuffering && viewModel.error == nil {
                if viewModel.showIntroSkip {
                    introSkipPill
                }
                if viewModel.showCreditsSkip {
                    creditsSkipPill
                }
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .onChange(of: activePopover) { _, value in
            if value != nil { viewModel.pinControlsVisible() }
            else { viewModel.resumeAutoHide() }
        }
    }

    /// The controls over the video. The geometry reader pins them to the
    /// player's own bounds: they share `PlayerView`'s layer with the player
    /// notice, and inside the full-screen cover a bar wider than the screen
    /// would otherwise stretch that layer and push the notice off both edges
    /// in portrait.
    private var overlay: some View {
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
                // The safe area already keeps the bottom row clear of the
                // home indicator, so only a hairline more is needed.
                .padding(.bottom, 2)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(.easeOut(duration: 0.18), value: viewModel.isTimelineScrubbing)
            }
        }
    }

    /// The top strip, centre buttons and selector row fade back while
    /// scrubbing so the preview bubble has the screen.
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
                // The rotation buttons are a separate overlay that fades with
                // these controls. Reserve their exact width so they never overlap.
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
        // PiP stays mounted with the rest of the top strip. AVKit can report
        // the source ready a run loop later, which should only enable the
        // button, never make it pop in after the viewer's tap.
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
                    AirPlayRoutePicker(onPresentingRoutes: pinWhilePresentingRoutes)
                        .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
                        .vividPlayerGlass(in: Circle(), interactive: true)
                }
            }
        }
    }

    /// The AirPlay route sheet holds the controls up while it's open.
    func pinWhilePresentingRoutes(_ isPresentingRoutes: Bool) {
        if isPresentingRoutes { viewModel.pinControlsVisible() }
        else { viewModel.resumeAutoHide() }
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

    /// "SEVERANCE · S2:E4": the series title and episode tag for an episode,
    /// the release year for a movie, and nothing until metadata arrives.
    var titleEyebrow: String? {
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

    var heroTitle: String {
        let primary = viewModel.metadata.primaryTitle
        return primary.isEmpty ? viewModel.title : primary
    }

    // MARK: - Centre

    /// Every circle matches the detail page's 44-point close and remote
    /// controls. Play and pause keep a white tint without a larger disc.
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
                    // play.fill looks left-heavy in a circle, so it moves
                    // towards the optical centre.
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

    var timeRow: some View {
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
                sleepTimerChip
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

    private var sleepTimerChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds))
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
    }

    /// The scrub position while scrubbing, otherwise the playback position.
    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    // MARK: - Scrubber

    /// A thumbless capsule: the whole bar is the handle.
    var progressSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.duration > 0
                ? min(max(displayTime / viewModel.duration, 0), 1)
                : 0
            let barHeight: CGFloat = viewModel.isScrubbing ? 12 : 6

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // The buffered range from the engine's telemetry. Routes
                // that can't report a comparable value leave it empty.
                if let buffered = bufferedFraction, buffered > progress {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(width * buffered, barHeight), height: barHeight)
                }

                openingSkipRanges(width: width, height: barHeight)

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
            // The scrubber only drags, so VoiceOver gets an adjustable
            // element that seeks through the same 10-second skips.
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

    /// The preview frame, time and chapter shown above the finger while
    /// scrubbing, read from the scrub position the view model keeps.
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
        return Self.chapterName(chapter)
    }

    /// A chapter's title, or "Chapter 3" when the file doesn't name it.
    static func chapterName(_ chapter: PlayerChapterInfo) -> String {
        chapter.title ?? String(localized: "Chapter \(chapter.index + 1)", comment: "Fallback name for an untitled chapter")
    }

    /// The intro and recap ranges, tinted on the track.
    @ViewBuilder
    private func openingSkipRanges(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(viewModel.openingSkipRanges.enumerated()), id: \.offset) { _, range in
            if viewModel.duration > 0 {
                let start = min(max(range.start / viewModel.duration, 0), 1)
                let end = min(max(range.end / viewModel.duration, 0), 1)
                if end > start {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.cyan.opacity(0.4))
                        .frame(width: width * (end - start), height: height)
                        .offset(x: width * start)
                }
            }
        }
    }

    // MARK: - Skip buttons

    /// One pill for both intro states: "Skip Intro" while the range plays,
    /// then "Skip Intro · N" with a cancel button beside it once the
    /// auto-skip countdown starts.
    private var introSkipPill: some View {
        skipPillPlacement {
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
    }

    private var creditsSkipPill: some View {
        skipPillPlacement {
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
    }

    /// Bottom right, the same distance above the controls whether they're
    /// showing or hidden, and at the foot of the video when half folded.
    private func skipPillPlacement<Pill: View>(@ViewBuilder _ pill: () -> Pill) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                pill()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, tabletop == nil ? bottomControlsHeight + 24 : 16)
        }
        .duoTabletopTopHalf(tabletop)
        .transition(.opacity)
    }
}
#endif
