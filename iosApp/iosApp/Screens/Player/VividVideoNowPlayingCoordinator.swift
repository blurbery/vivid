import Foundation
import MediaPlayer
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Publishes Vivid video to the system's Now Playing and routes the remote
/// commands that come back.
///
/// Native video publishes through the `MPNowPlayingSession` tied to the
/// engine's `AVPlayer`. The software renderer has no session of its own, so
/// it uses the process-wide centres directly. Both go through one rebinding
/// point, so commands and metadata are never left registered on the shared
/// centres and a player's session at the same time.
@MainActor
final class VividVideoNowPlayingCoordinator {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var isPaused: () -> Bool
        /// The position in source-media time, not the transport's own clock.
        var currentTime: () -> Double
        /// Takes a target in source-media time.
        var seek: (Double) -> Void
        var stop: (() -> Void)?
        var next: (() -> Void)?
        var isNextEnabled: () -> Bool = { false }
        /// Whether the transport behind these handlers can do anything.
        /// `VividPlaybackController.play()` quietly does nothing once a failed
        /// load has cleared its epoch, so answering `.success` then would
        /// report work the system never sees. A host that doesn't say counts
        /// as able.
        var hasActiveLoad: () -> Bool = { true }
    }

    /// Where commands and metadata currently go.
    private enum Target: Equatable {
        case nothing
        case processWide
        #if os(iOS) || os(tvOS)
        /// Carries no payload on purpose. An identity payload would make
        /// equality an address check, and a released session can be replaced
        /// by a new one at the same address, which would then compare equal
        /// and skip the unbind. The session is retained and compared by
        /// reference instead.
        case playerSession
        #endif
    }

    /// The skip interval offered to the system and used when a skip command
    /// doesn't carry its own.
    private static let skipSeconds: TimeInterval = 10

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "VideoNowPlaying"
    )

    #if os(tvOS)
    /// AVKit publishes native video itself on Apple TV; this only lends it
    /// Vivid's title and artwork.
    var nativeMetadataHandler: ((String, MPMediaItemArtwork?) -> Void)?
    #endif

    private var target: Target = .nothing
    private var currentHandlers: Handlers?
    private var commandCentre: MPRemoteCommandCenter?
    private var infoCentre: MPNowPlayingInfoCenter?
    private var registeredTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var info: [String: Any] = [:]
    private var requestedArtworkURL: URL?
    private var artworkTask: Task<Void, Never>?

    #if os(iOS) || os(tvOS)
    /// Retained rather than weak: comparing the bound session by reference
    /// is only safe while it can't be freed underneath. Released when the
    /// binding ends, so it's held exactly as long as the binding.
    private var boundSession: MPNowPlayingSession?

    /// Binds to the engine's native video session, or to the process-wide
    /// centres only for a route that has no session to offer.
    func attach(
        session: MPNowPlayingSession?,
        useSharedFallback: Bool,
        handlers: Handlers
    ) {
        let wanted: Target
        if session != nil {
            wanted = .playerSession
        } else {
            wanted = useSharedFallback ? .processWide : .nothing
        }
        currentHandlers = handlers

        if wanted == target, wanted != .playerSession || session === boundSession {
            // Still bound to the same place. A native host can outlive an
            // item reload while another app briefly takes over Now Playing,
            // so ask for it back.
            session?.becomeActiveIfPossible(completion: { _ in })
            refreshCommandAvailability()
            publish()
            return
        }

        unbind()
        target = wanted
        boundSession = session

        switch wanted {
        case .nothing:
            break
        case .processWide:
            bindProcessWideCentres()
        case .playerSession:
            guard let session else { return }
            // Protocol V3 can play on a transport clock offset from the
            // source. Vivid publishes by hand so the system scrubber, and the
            // seeks it sends back, stay in source-media time.
            session.automaticallyPublishesNowPlayingInfo = false
            commandCentre = session.remoteCommandCenter
            infoCentre = session.nowPlayingInfoCenter
            session.becomeActiveIfPossible(completion: { _ in })
        }

        addCommandTargets()
        publish()
    }
    #endif

    func detach() {
        currentHandlers = nil
        unbind()
        target = .nothing
        artworkTask?.cancel()
        artworkTask = nil
        requestedArtworkURL = nil
        info = [:]
    }

    /// Publishes the source-media timeline. `position` and `duration` have to
    /// share one time axis, because the system sends scrub targets back on
    /// the axis this dictionary describes.
    func update(
        title: String,
        duration: Double,
        position: Double,
        isPlaying: Bool,
        playbackRate: Double = 1
    ) {
        let rate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
        let length = duration.isFinite ? max(0, duration) : 0
        let elapsed = position.isFinite ? max(0, position) : 0

        info[MPMediaItemPropertyTitle] = title
        if length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = length
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(
            value: MPNowPlayingInfoMediaType.video.rawValue
        )
        publish()
        refreshCommandAvailability()
    }

    func setArtworkURL(_ url: URL?) {
        guard currentHandlers != nil, url != requestedArtworkURL else { return }
        requestedArtworkURL = url
        artworkTask?.cancel()
        artworkTask = nil

        if let url {
            artworkTask = Task { [weak self] in
                await self?.loadArtwork(from: url)
            }
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            publish()
        }
    }

    // MARK: - Artwork

    private func loadArtwork(from url: URL) async {
        let payload: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
                Self.log.warning("Artwork fetch HTTP \(status)")
                return
            }
            payload = data
        } catch is CancellationError {
            return
        } catch {
            Self.log.warning("Artwork fetch failed: \(String(describing: error), privacy: .private)")
            return
        }

        #if canImport(UIKit)
        guard let image = UIImage(data: payload) else {
            Self.log.warning("Artwork decode failed")
            return
        }
        // Another URL, or a detach, may have come along during the fetch.
        guard url == requestedArtworkURL, currentHandlers != nil else { return }
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        publish()
        #endif
    }

    // MARK: - Commands

    private func addCommandTargets() {
        guard let centre = commandCentre else { return }
        let offeredSkip = [NSNumber(value: Self.skipSeconds)]

        centre.playCommand.isEnabled = true
        addLoadedTarget(on: centre.playCommand) { handlers, _ in
            handlers.play()
        }

        centre.pauseCommand.isEnabled = true
        addLoadedTarget(on: centre.pauseCommand) { handlers, _ in
            handlers.pause()
        }

        centre.togglePlayPauseCommand.isEnabled = true
        addLoadedTarget(on: centre.togglePlayPauseCommand) { handlers, _ in
            if handlers.isPaused() {
                handlers.play()
            } else {
                handlers.pause()
            }
        }

        centre.skipForwardCommand.preferredIntervals = offeredSkip
        centre.skipForwardCommand.isEnabled = true
        addLoadedTarget(on: centre.skipForwardCommand) { handlers, event in
            handlers.seek(handlers.currentTime() + Self.skipLength(of: event))
        }

        centre.skipBackwardCommand.preferredIntervals = offeredSkip
        centre.skipBackwardCommand.isEnabled = true
        addLoadedTarget(on: centre.skipBackwardCommand) { handlers, event in
            handlers.seek(max(0, handlers.currentTime() - Self.skipLength(of: event)))
        }

        centre.changePlaybackPositionCommand.isEnabled = true
        addTarget(on: centre.changePlaybackPositionCommand) { [weak self] event in
            guard let handlers = self?.currentHandlers,
                  let scrub = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            if !handlers.hasActiveLoad() { return .noActionableNowPlayingItem }
            handlers.seek(scrub.positionTime)
            return .success
        }

        // Stop and next are switched on by the availability check alone.
        addTarget(on: centre.stopCommand) { [weak self] _ in
            guard let handlers = self?.currentHandlers, let stop = handlers.stop else {
                return .noSuchContent
            }
            if !handlers.hasActiveLoad() { return .noActionableNowPlayingItem }
            stop()
            return .success
        }

        addTarget(on: centre.nextTrackCommand) { [weak self] _ in
            guard let handlers = self?.currentHandlers, handlers.isNextEnabled(), let next = handlers.next else {
                return .noSuchContent
            }
            next()
            return .success
        }

        refreshCommandAvailability()
    }

    /// A transport command: fails with no handlers, reports nothing to act
    /// on without a load, and otherwise acts and succeeds.
    private func addLoadedTarget(
        on command: MPRemoteCommand,
        _ act: @escaping (Handlers, MPRemoteCommandEvent) -> Void
    ) {
        addTarget(on: command) { [weak self] event in
            guard let handlers = self?.currentHandlers else { return .commandFailed }
            if !handlers.hasActiveLoad() { return .noActionableNowPlayingItem }
            act(handlers, event)
            return .success
        }
    }

    nonisolated private static func skipLength(of event: MPRemoteCommandEvent) -> TimeInterval {
        (event as? MPSkipIntervalCommandEvent)?.interval ?? skipSeconds
    }

    private func addTarget(
        on command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        registeredTargets.append((command, command.addTarget(handler: handler)))
    }

    private func removeCommandTargets() {
        for registration in registeredTargets {
            registration.command.removeTarget(registration.token)
        }
        registeredTargets.removeAll()
    }

    /// The process-wide command centre outlives this binding, and a command
    /// left enabled with no target keeps offering a transport nobody drives.
    /// So whatever the binding switched on is switched off with it: every
    /// command `addCommandTargets` and `refreshCommandAvailability` can enable.
    private func disableBoundCommands(on centre: MPRemoteCommandCenter) {
        let bound: [MPRemoteCommand] = [
            centre.playCommand,
            centre.pauseCommand,
            centre.togglePlayPauseCommand,
            centre.skipForwardCommand,
            centre.skipBackwardCommand,
            centre.changePlaybackPositionCommand,
            centre.stopCommand,
            centre.nextTrackCommand,
        ]
        for command in bound {
            command.isEnabled = false
        }
    }

    private func refreshCommandAvailability() {
        guard let centre = commandCentre else { return }
        centre.stopCommand.isEnabled = currentHandlers?.stop != nil
        if let handlers = currentHandlers {
            centre.nextTrackCommand.isEnabled = handlers.next != nil && handlers.isNextEnabled()
        } else {
            centre.nextTrackCommand.isEnabled = false
        }
    }

    private func publish() {
        #if os(tvOS)
        let title = info[MPMediaItemPropertyTitle] as? String ?? ""
        nativeMetadataHandler?(title, info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        #endif
        guard let infoCentre else { return }
        infoCentre.nowPlayingInfo = info.isEmpty ? nil : info
    }

    // MARK: - Binding

    /// Takes the process-wide centres and registers a claim on them, so
    /// another coordinator's teardown can't strip them from under this one.
    private func bindProcessWideCentres() {
        commandCentre = MPRemoteCommandCenter.shared()
        infoCentre = MPNowPlayingInfoCenter.default()
        ProcessWideNowPlayingClaims.shared.claim(self) { [weak self] in
            self?.reclaimProcessWideCentres()
        }
    }

    /// Registers the targets and publishes the metadata again after another
    /// claimant let go of the process-wide centres. Does nothing unless this
    /// coordinator is still bound to them.
    private func reclaimProcessWideCentres() {
        guard commandCentre === MPRemoteCommandCenter.shared() else { return }
        removeCommandTargets()
        addCommandTargets()
        publish()
    }

    private func unbind() {
        removeCommandTargets()
        // On the process-wide centres, disabling commands and clearing the
        // metadata affects every coordinator, so only the last claimant may
        // do it. Otherwise the remaining claimant is restored instead.
        let isLastHolder: Bool
        if commandCentre === MPRemoteCommandCenter.shared() {
            isLastHolder = ProcessWideNowPlayingClaims.shared.release(self)
        } else {
            isLastHolder = true
        }
        if isLastHolder {
            if let commandCentre {
                disableBoundCommands(on: commandCentre)
            }
            infoCentre?.nowPlayingInfo = nil
        }
        commandCentre = nil
        infoCentre = nil
        #if os(iOS) || os(tvOS)
        boundSession = nil
        #endif
    }
}

/// Shares `MPRemoteCommandCenter.shared()` and `MPNowPlayingInfoCenter.default()`
/// between video coordinators that overlap while one player hands over to
/// the next.
///
/// Both centres belong to the whole process, so one coordinator tearing down
/// would otherwise switch off every shared command and clear the shared
/// metadata while another still has targets registered. Claims are keyed by
/// coordinator: only the last one out does the teardown, and when one leaves
/// early, the newest remaining claimant puts its own targets and metadata
/// back in case the leaver overwrote them.
@MainActor
private final class ProcessWideNowPlayingClaims {
    static let shared = ProcessWideNowPlayingClaims()

    private struct Claim {
        weak var holder: AnyObject?
        let reclaim: () -> Void
    }

    /// Oldest first.
    private var holders: [Claim] = []

    private init() {}

    /// Records `holder` as using the centres. `reclaim` must register that
    /// holder's targets and publish its metadata again, and do nothing if it
    /// has since moved off the shared centres.
    func claim(_ holder: AnyObject, reclaim: @escaping () -> Void) {
        dropReleasedHolders()
        holders.removeAll { $0.holder === holder }
        holders.append(Claim(holder: holder, reclaim: reclaim))
    }

    /// Removes `holder`'s claim. Returns `true` when nobody else holds the
    /// centres, so the caller may switch shared commands off and clear the
    /// shared metadata. Otherwise the newest remaining claimant is restored
    /// and the answer is `false`.
    func release(_ holder: AnyObject) -> Bool {
        dropReleasedHolders()
        holders.removeAll { $0.holder === holder }
        guard let newest = holders.last else { return true }
        newest.reclaim()
        return false
    }

    private func dropReleasedHolders() {
        holders.removeAll { $0.holder == nil }
    }
}
