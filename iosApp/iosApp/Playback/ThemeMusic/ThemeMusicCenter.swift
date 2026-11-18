import AVFoundation
import Observation
import OSLog
import SwiftUI
import UIKit

/// A detail page's hold on theme music, returned by
/// ``ThemeMusicCenter/claim(_:)``. Only the newest claim counts: an older
/// page's ``ThemeMusicCenter/update(_:item:)`` or
/// ``ThemeMusicCenter/release(_:)`` changes nothing.
struct ThemeMusicClaim: Hashable, Sendable {
    fileprivate let id: UInt64
}

/// One theme song in one signed-in context. Pages whose lookups give the
/// same key share the song (a series, its seasons and its episodes), and a
/// server, profile or provider switch never reuses another context's state.
struct ThemeMusicKey: Hashable, Sendable {
    let provider: String
    let serverID: String
    let profileID: String
    let ownerID: String
    let songID: String
}

/// The decisions behind theme music, kept apart from `AVPlayer` so they can
/// be tested.
enum ThemeMusicPolicy {
    enum Decision: Equatable {
        /// The song is already playing: carry on without restarting it.
        case keepPlaying
        /// The song has played once (or video playback stopped it), so it
        /// stays quiet for as long as pages keep claiming it.
        case stayQuiet
        /// A different song: start it from the beginning.
        case play
    }

    static func decision(for key: ThemeMusicKey, playing: ThemeMusicKey?, finished: ThemeMusicKey?) -> Decision {
        if key == playing { return .keepPlaying }
        if key == finished { return .stayQuiet }
        return .play
    }

    /// What a finished lookup means for the song that is playing.
    enum LookupOutcome: Equatable {
        /// The lookup couldn't get an answer. The current song is left alone
        /// and the hold timeout ends it unless another claim takes over.
        case leaveAlone
        /// The title has no theme: fade out whatever is playing.
        case stop
        /// The title has a theme song: decide whether to keep, skip or play it.
        case consider(ThemeSongLookup)
    }

    static func outcome(of result: ThemeSongLookupResult) -> LookupOutcome {
        switch result {
        case .found(let lookup): .consider(lookup)
        case .none: .stop
        case .failed: .leaveAlone
        }
    }

    /// True when the unreachable server is the only thing stopping a start,
    /// so the claim is worth trying again once the server is back. Another
    /// app's audio, Picture in Picture or a video player never earn a retry.
    static func shouldRetryWhenReachable(_ conditions: Conditions) -> Bool {
        guard !conditions.isServerReachable else { return false }
        var conditions = conditions
        conditions.isServerReachable = true
        conditions.isAppActive = true
        return canStart(conditions)
    }

    /// Everything that has to be true for theme music to start or resume.
    struct Conditions: Equatable {
        var isEnabled: Bool
        var isPictureInPictureEngaged: Bool
        /// Another app's audio is playing (the session's
        /// `secondaryAudioShouldBeSilencedHint`).
        var isOtherAudioPlaying: Bool
        var isServerReachable: Bool
        var isVideoPlayerOnScreen: Bool
        var isAppActive: Bool
    }

    static func canStart(_ conditions: Conditions) -> Bool {
        conditions.isEnabled
            && !conditions.isPictureInPictureEngaged
            && !conditions.isOtherAudioPlaying
            && conditions.isServerReachable
            && !conditions.isVideoPlayerOnScreen
            && conditions.isAppActive
    }

    /// The player volume for the user's percentage, kept within 5...100.
    static func targetVolume(percent: Int) -> Float {
        Float(min(max(percent, 5), 100)) / 100
    }
}

extension ThemeMusicItem {
    init(_ detail: ItemDetail) {
        self.init(contentID: detail.contentId, type: detail.type, seriesID: detail.seriesId)
    }
}

/// Plays the theme song of the movie, series, season or episode page on
/// screen, quietly and once.
///
/// - A page calls ``claim(_:)`` as it appears, even before its detail has
///   loaded (a hold that keeps the current song going), then ``update(_:item:)``
///   once it knows its title, and ``release(_:)`` as it disappears. The
///   ``SwiftUI/View/themeMusicClaim(_:)`` modifier does all three.
/// - A newer claim cancels any lookup still running for an older one, so a
///   slow response can never start the previous title's theme.
/// - The same song keeps playing across pages; a different one fades the old
///   one out and starts. A song that has played to the end stays quiet until
///   a different song is claimed.
/// - A release waits ``releaseGrace`` before fading out, so a push or a
///   replace to a page that claims straight away doesn't cut the music.
/// - ``videoPlayerDidAppear()`` stops at once and marks the song as played,
///   so it doesn't come back when the player closes. ``sessionDidChange(signedIn:)``
///   stops at once and forgets everything after a sign-out or a server,
///   provider or profile switch.
/// - A lookup that fails (timeout, network error) is not "no theme": the
///   current song carries on until the hold timeout ends it.
///
/// Some skips are deliberate and never retried, the way Silo's own app
/// behaves: a page claimed while another app's audio is playing stays quiet,
/// and after Picture in Picture or a video the theme doesn't come back. Only
/// two blockers earn a retry of the current claim: the app being inactive
/// (retried when it becomes active) and the server being unreachable
/// (retried when ``ConnectionMonitor`` sees the server again). A failed
/// lookup is retried the same way, so only when the server was marked
/// unreachable in the meantime: theme requests don't report reachability
/// themselves.
///
/// It sets the shared audio session to `.ambient` only when it starts a song
/// and no video is up, and never deactivates the session. The video engine
/// switches the session back to `.playback` whenever it loads, so the engine
/// always wins.
@MainActor
final class ThemeMusicCenter {
    static let shared = ThemeMusicCenter()

    private static let log = Logger(subsystem: "com.blurbery.vivid", category: "ThemeMusic")
    static let fadeInDuration: Duration = .milliseconds(300)
    static let fadeOutDuration: Duration = .milliseconds(500)
    /// How long a released song keeps playing in case the next page claims it.
    static let releaseGrace: Duration = .milliseconds(500)
    /// How long a page that hasn't loaded its title holds the current song.
    static let holdTimeout: Duration = .seconds(4)
    /// The video engine hands the audio session back asynchronously after
    /// the player closes. No song starts until this long after that.
    static let videoSettleDelay: Duration = .seconds(2)
    private static let fadeSteps = 15

    private let player = AVPlayer()

    private var nextClaimID: UInt64 = 0
    private var currentClaim: ThemeMusicClaim?
    private var currentItem: ThemeMusicItem?
    /// Looks up, fetches and starts the current claim's song.
    private var resolveTask: Task<Void, Never>?
    /// A release's grace or a hold's timeout, ending in a fade out.
    private var delayedStopTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var fadeToken: UInt64 = 0
    private var isFadingOutToStop = false

    /// The song loaded in the player, playing or paused while the app is
    /// inactive.
    private var playingKey: ThemeMusicKey?
    /// The song that has played once. Same-key claims stay quiet.
    private var finishedKey: ThemeMusicKey?
    /// The title on screen when video playback stopped the music before its
    /// lookup finished. Its song is treated as played once it's known.
    private var suppressedItem: ThemeMusicItem?
    private var isPausedForInactiveApp = false
    /// A start was refused only because the app wasn't active.
    private var retriesWhenActive = false
    /// A start was refused because the server was unreachable, or the
    /// lookup failed: the claim tries again when the server is back.
    private var retriesWhenReachable = false

    /// The switch as last seen, so turning it back on can start a song.
    private var wasEnabled = true
    /// Reachability as last seen. `ConnectionMonitor` reports a change on
    /// every request, so only a real change from unreachable counts.
    private var wasServerReachable = true

    /// Only one video player is ever on screen, so the latest appear or
    /// disappear wins. A plain flag can't get stuck the way a count could if
    /// an appear ever fired twice.
    private var isVideoPlayerOnScreen = false
    private var lastVideoPlayerExit: ContinuousClock.Instant?

    private var lastSessionIdentity: SessionIdentity

    private var itemObservers: [NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?
    /// Waits for a newly loaded song to actually start before fading it in,
    /// so a remote stream that buffers for a moment still fades in.
    private var playbackStartObservation: NSKeyValueObservation?

    private init() {
        lastSessionIdentity = .current
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .pause
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillResignActive() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        wasEnabled = PlayerSettings.shared.themeMusicEnabled
        observeSettings()
        wasServerReachable = ConnectionMonitor.shared.isServerReachable
        observeReachability()
        #if os(iOS)
        observePictureInPicture()
        #endif
    }

    // MARK: Pages

    /// Takes over theme music for a page that has just appeared. Pass `nil`
    /// while the page is still loading: the current song keeps playing for up
    /// to ``holdTimeout`` until ``update(_:item:)`` names the title.
    func claim(_ item: ThemeMusicItem?) -> ThemeMusicClaim {
        nextClaimID &+= 1
        let claim = ThemeMusicClaim(id: nextClaimID)
        currentClaim = claim
        currentItem = nil
        // A page that comes back during a fade out picks the song up again.
        if isFadingOutToStop, ThemeMusicPolicy.canStart(conditions) {
            fadeIn()
        }
        update(claim, item: item)
        return claim
    }

    /// Names (or changes) the title a claim is for.
    func update(_ claim: ThemeMusicClaim, item: ThemeMusicItem?) {
        guard currentClaim == claim else { return }
        currentItem = item
        retriesWhenActive = false
        retriesWhenReachable = false
        resolveTask?.cancel()
        resolveTask = nil
        // The previous song holds until this claim's lookup decides, but no
        // longer than the hold timeout.
        scheduleFadeOut(after: Self.holdTimeout) { [weak self] in
            self?.currentClaim == claim
        }
        guard let item else { return }
        resolveTask = Task { [weak self] in
            await self?.resolve(item, claim: claim)
        }
    }

    /// The page has gone. Counts only for the newest claim; the song fades
    /// out after ``releaseGrace`` unless another page claims first.
    func release(_ claim: ThemeMusicClaim) {
        guard currentClaim == claim else { return }
        currentClaim = nil
        currentItem = nil
        retriesWhenActive = false
        retriesWhenReachable = false
        resolveTask?.cancel()
        resolveTask = nil
        scheduleFadeOut(after: Self.releaseGrace) { [weak self] in
            self?.currentClaim == nil
        }
    }

    // MARK: Video and session

    /// Every video player calls this as it appears. Theme music stops at once,
    /// the song counts as played, and nothing starts while the player is up.
    func videoPlayerDidAppear() {
        isVideoPlayerOnScreen = true
        stopNow()
    }

    func videoPlayerDidDisappear() {
        isVideoPlayerOnScreen = false
        lastVideoPlayerExit = .now
    }

    /// Stops at once, without a fade. The playing song, or the claimed title
    /// whose lookup hadn't finished, counts as played so it doesn't come back
    /// when the page shows again; a different title resets that.
    func stopNow() {
        if let currentItem { suppressedItem = currentItem }
        endClaim()
        if playingKey != nil { stopPlayer(markFinished: true) }
    }

    /// Called on every sign-in state, server or profile change. A sign-out, or
    /// a server, provider or profile that differs from the last one seen,
    /// stops at once and forgets what has played. A repeat of the same
    /// session (launch, `loading` to signed in) changes nothing.
    func sessionDidChange(signedIn: Bool = true) {
        let identity = SessionIdentity.current
        defer { lastSessionIdentity = identity }
        guard !signedIn || identity != lastSessionIdentity else { return }
        isVideoPlayerOnScreen = false
        endClaim()
        stopPlayer(markFinished: false)
        finishedKey = nil
        suppressedItem = nil
    }

    private func endClaim() {
        currentClaim = nil
        currentItem = nil
        retriesWhenActive = false
        retriesWhenReachable = false
        resolveTask?.cancel()
        resolveTask = nil
        delayedStopTask?.cancel()
        delayedStopTask = nil
    }

    // MARK: Resolving a claim

    private func isCurrent(_ claim: ThemeMusicClaim) -> Bool {
        currentClaim == claim && !Task.isCancelled
    }

    private func resolve(_ item: ThemeMusicItem, claim: ThemeMusicClaim) async {
        guard PlayerSettings.shared.themeMusicEnabled else {
            fadeOutAndStop()
            return
        }
        let identity = SessionIdentity.current
        let result = await ThemeMusicSource.lookup(for: item)
        guard isCurrent(claim), SessionIdentity.current == identity else { return }
        // A different title on screen ends the suppression, whatever the
        // lookup found.
        if suppressedItem != item { suppressedItem = nil }
        let lookup: ThemeSongLookup
        switch ThemeMusicPolicy.outcome(of: result) {
        case .leaveAlone:
            // No answer isn't "no theme". The hold timeout set by `update`
            // stays in place and ends the current song, and the claim tries
            // again once the server is reachable.
            retriesWhenReachable = true
            return
        case .stop:
            delayedStopTask?.cancel()
            delayedStopTask = nil
            fadeOutAndStop()
            return
        case .consider(let found):
            delayedStopTask?.cancel()
            delayedStopTask = nil
            lookup = found
        }
        let key = identity.key(for: lookup)
        if suppressedItem == item {
            finishedKey = key
        }
        switch ThemeMusicPolicy.decision(for: key, playing: playingKey, finished: finishedKey) {
        case .keepPlaying:
            if isFadingOutToStop || player.volume < ThemeMusicPolicy.targetVolume(percent: volumePercent) {
                if ThemeMusicPolicy.canStart(conditions) { fadeIn() }
            }
            return
        case .stayQuiet:
            fadeOutAndStop()
            return
        case .play:
            finishedKey = nil
        }

        if let fade = fadeOutAndStop() { await fade.value }
        guard isCurrent(claim) else { return }
        if playingKey != nil { stopPlayer(markFinished: false) }
        guard canStartOrDefer() else { return }
        guard await waitForVideoSettle(), isCurrent(claim) else { return }

        let stream = await ThemeMusicSource.stream(for: lookup)
        guard isCurrent(claim), SessionIdentity.current == identity else { return }
        guard let stream else {
            Self.log.debug("No playable theme song stream")
            return
        }
        guard canStartOrDefer() else { return }
        start(stream, key: key)
    }

    /// Checks the start conditions. Refused only for an inactive app, the
    /// claim tries again when the app becomes active; refused only for an
    /// unreachable server (perhaps with the app inactive too), it tries again
    /// when the server is back. Any other blocker is a deliberate skip.
    private func canStartOrDefer() -> Bool {
        let conditions = self.conditions
        guard !ThemeMusicPolicy.canStart(conditions) else { return true }
        retriesWhenReachable = ThemeMusicPolicy.shouldRetryWhenReachable(conditions)
        var whenActive = conditions
        whenActive.isAppActive = true
        retriesWhenActive = ThemeMusicPolicy.canStart(whenActive)
        return false
    }

    /// Waits out ``videoSettleDelay`` after a player closed. False if cancelled.
    private func waitForVideoSettle() async -> Bool {
        guard let exit = lastVideoPlayerExit else { return true }
        let remaining = Self.videoSettleDelay - (ContinuousClock.now - exit)
        guard remaining > .zero else { return true }
        do {
            try await Task.sleep(for: remaining)
        } catch {
            return false
        }
        return true
    }

    private var conditions: ThemeMusicPolicy.Conditions {
        #if os(iOS)
        let isPictureInPictureEngaged = PictureInPictureCoordinator.shared.isEngaged
        #else
        let isPictureInPictureEngaged = false
        #endif
        return ThemeMusicPolicy.Conditions(
            isEnabled: PlayerSettings.shared.themeMusicEnabled,
            isPictureInPictureEngaged: isPictureInPictureEngaged,
            isOtherAudioPlaying: AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint,
            isServerReachable: ConnectionMonitor.shared.isServerReachable,
            isVideoPlayerOnScreen: isVideoPlayerOnScreen,
            isAppActive: UIApplication.shared.applicationState == .active
        )
    }

    private var volumePercent: Int { PlayerSettings.shared.themeMusicVolumePercent }

    // MARK: Playing

    private func start(_ stream: ThemeSongStream, key: ThemeMusicKey) {
        // Only reached with no video player up and no Picture in Picture, so
        // the engine isn't holding the session. It sets `.playback` again
        // itself when it next loads.
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient {
            do {
                try session.setCategory(.ambient, mode: .default)
            } catch {
                Self.log.error("Theme music audio session refused: \((error as NSError).code, privacy: .public)")
                return
            }
        }
        let asset: AVURLAsset
        if stream.url.isFileURL || stream.headers.isEmpty {
            asset = AVURLAsset(url: stream.url)
        } else {
            asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        }
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.volume = 0
        player.replaceCurrentItem(with: item)
        playingKey = key
        isPausedForInactiveApp = false
        Self.log.debug("Theme music started")
        player.play()
        // Fade in from the moment audio is actually playing, not from when
        // the item was loaded.
        playbackStartObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackStartObservation != nil, self.player.currentItem === item else { return }
                self.playbackStartObservation?.invalidate()
                self.playbackStartObservation = nil
                self.fadeIn()
            }
        }
    }

    private func fadeIn() {
        isFadingOutToStop = false
        if player.timeControlStatus == .paused { player.play() }
        startFade(over: Self.fadeInDuration, to: { [weak self] in
            ThemeMusicPolicy.targetVolume(percent: self?.volumePercent ?? 30)
        }, then: nil)
    }

    /// Fades the loaded song out and unloads it. Returns the fade to await,
    /// or nil when nothing needed fading.
    @discardableResult
    private func fadeOutAndStop() -> Task<Void, Never>? {
        guard playingKey != nil else { return nil }
        if isFadingOutToStop, let fadeTask { return fadeTask }
        guard player.timeControlStatus != .paused else {
            stopPlayer(markFinished: false)
            return nil
        }
        isFadingOutToStop = true
        // A song still buffering must not fade in once it starts.
        playbackStartObservation?.invalidate()
        playbackStartObservation = nil
        return startFade(over: Self.fadeOutDuration, to: { 0 }) { [weak self] in
            self?.stopPlayer(markFinished: false)
        }
    }

    @discardableResult
    private func startFade(
        over duration: Duration,
        to target: @escaping () -> Float,
        then completion: (() -> Void)?
    ) -> Task<Void, Never> {
        fadeTask?.cancel()
        fadeToken &+= 1
        let token = fadeToken
        let task = Task { [weak self] in
            guard let self else { return }
            let from = self.player.volume
            for step in 1...Self.fadeSteps {
                do {
                    try await Task.sleep(for: duration / Self.fadeSteps)
                } catch {
                    return
                }
                guard self.fadeToken == token else { return }
                let progress = Float(step) / Float(Self.fadeSteps)
                self.player.volume = from + (target() - from) * progress
            }
            guard self.fadeToken == token else { return }
            self.fadeTask = nil
            completion?()
        }
        fadeTask = task
        return task
    }

    /// Unloads the song at once. `markFinished` keeps its key quiet until a
    /// different song is claimed.
    private func stopPlayer(markFinished: Bool) {
        fadeTask?.cancel()
        fadeTask = nil
        fadeToken &+= 1
        isFadingOutToStop = false
        isPausedForInactiveApp = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        if markFinished, let playingKey { finishedKey = playingKey }
        if playingKey != nil { Self.log.debug("Theme music stopped") }
        playingKey = nil
    }

    private func scheduleFadeOut(after delay: Duration, when condition: @escaping () -> Bool) {
        delayedStopTask?.cancel()
        guard playingKey != nil else {
            delayedStopTask = nil
            return
        }
        delayedStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, condition() else { return }
            self.delayedStopTask = nil
            self.fadeOutAndStop()
        }
    }

    // MARK: The player item

    private func observe(_ item: AVPlayerItem) {
        removeItemObservers()
        let center = NotificationCenter.default
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            itemObservers.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated { self?.itemEnded(item) }
            })
        }
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self, weak item] in self?.itemEnded(item) }
        }
    }

    private func removeItemObservers() {
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playbackStartObservation?.invalidate()
        playbackStartObservation = nil
    }

    /// Played to the end, or failed: either way it plays once, so the same
    /// song doesn't retry while its pages are open.
    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, player.currentItem === item else { return }
        stopPlayer(markFinished: true)
    }

    // MARK: App state

    private func appWillResignActive() {
        guard playingKey != nil else { return }
        if isFadingOutToStop {
            stopPlayer(markFinished: false)
            return
        }
        fadeTask?.cancel()
        fadeTask = nil
        fadeToken &+= 1
        player.pause()
        isPausedForInactiveApp = true
    }

    private func appDidBecomeActive() {
        if isPausedForInactiveApp {
            isPausedForInactiveApp = false
            guard currentClaim != nil, ThemeMusicPolicy.canStart(conditions) else {
                stopPlayer(markFinished: false)
                return
            }
            player.volume = 0
            fadeIn()
        } else if retriesWhenActive, let currentClaim {
            update(currentClaim, item: currentItem)
        }
    }

    // MARK: Reachability

    private func observeReachability() {
        withObservationTracking {
            _ = ConnectionMonitor.shared.isServerReachable
        } onChange: { [weak self] in
            // Called before the new value is stored, and only once.
            Task { @MainActor [weak self] in
                self?.reachabilityDidChange()
                self?.observeReachability()
            }
        }
    }

    /// Retries the current claim when the server comes back, but only when
    /// an unreachable server or a failed lookup was what stopped it.
    private func reachabilityDidChange() {
        let isReachable = ConnectionMonitor.shared.isServerReachable
        defer { wasServerReachable = isReachable }
        guard isReachable, !wasServerReachable, retriesWhenReachable,
              playingKey == nil, let currentClaim, currentItem != nil else { return }
        update(currentClaim, item: currentItem)
    }

    #if os(iOS)
    /// Picture in Picture closing is when the engine hands the audio session
    /// back, so it starts the settle delay like a player closing does.
    private func observePictureInPicture() {
        withObservationTracking {
            _ = PictureInPictureCoordinator.shared.isEngaged
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                if !PictureInPictureCoordinator.shared.isEngaged {
                    self?.lastVideoPlayerExit = .now
                }
                self?.observePictureInPicture()
            }
        }
    }
    #endif

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = PlayerSettings.shared.themeMusicEnabled
            _ = PlayerSettings.shared.themeMusicVolumePercent
        } onChange: { [weak self] in
            // Called before the new value is stored, and only once.
            Task { @MainActor [weak self] in
                self?.settingsDidChange()
                self?.observeSettings()
            }
        }
    }

    private func settingsDidChange() {
        let isEnabled = PlayerSettings.shared.themeMusicEnabled
        defer { wasEnabled = isEnabled }
        guard isEnabled else {
            resolveTask?.cancel()
            resolveTask = nil
            fadeOutAndStop()
            return
        }
        if !wasEnabled, playingKey == nil, let currentClaim, currentItem != nil {
            // Switched back on with a page open.
            update(currentClaim, item: currentItem)
        } else if playingKey != nil, fadeTask == nil, playbackStartObservation == nil, !isPausedForInactiveApp {
            // A running fade picks the new volume up on its next step.
            player.volume = ThemeMusicPolicy.targetVolume(percent: volumePercent)
        }
    }
}

/// The signed-in context a song belongs to.
private struct SessionIdentity: Equatable {
    let provider: String
    let serverID: String
    let profileID: String

    @MainActor
    static var current: SessionIdentity {
        SessionIdentity(
            provider: MediaServerProvider.active.rawValue,
            serverID: ServerRegistry.activeServerIDSnapshot ?? "",
            profileID: ServerRegistry.shared.activeProfileId ?? ""
        )
    }

    func key(for lookup: ThemeSongLookup) -> ThemeMusicKey {
        ThemeMusicKey(
            provider: provider,
            serverID: serverID,
            profileID: profileID,
            ownerID: lookup.ownerID,
            songID: lookup.songID
        )
    }
}

// MARK: - Detail pages

private struct ThemeMusicClaimModifier: ViewModifier {
    let item: ThemeMusicItem?
    @State private var claim: ThemeMusicClaim?

    func body(content: Content) -> some View {
        content
            .onAppear {
                claim = ThemeMusicCenter.shared.claim(item)
            }
            .onChange(of: item) { _, item in
                guard let claim else { return }
                ThemeMusicCenter.shared.update(claim, item: item)
            }
            .onDisappear {
                if let claim { ThemeMusicCenter.shared.release(claim) }
                claim = nil
            }
    }
}

extension View {
    /// Plays `item`'s theme song while this detail page is on screen. Pass
    /// `nil` until the page knows its title; the current song holds meanwhile.
    func themeMusicClaim(_ item: ThemeMusicItem?) -> some View {
        modifier(ThemeMusicClaimModifier(item: item))
    }
}
