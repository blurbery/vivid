// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import Foundation
import Libmpv

/// Receives Lucid's properties and events on the main thread, in mpv's order.
protocol VividPlayerCoreDelegate: AnyObject {
    func onPropertyChange(name: String, value: Any?, sourceId: Int64?)
    func onEvent(name: String, data: [String: Any]?)
}

/// Why the bridge could not serve a request.
struct VividPlayerCoreError: LocalizedError {
    private let message: String
    var errorDescription: String? { message }

    /// The player was never set up, or has been disposed.
    static let notAvailable = VividPlayerCoreError(message: "Lucid is not available for this request.")
    /// The request was still waiting for mpv when the player was disposed.
    static let disposed = VividPlayerCoreError(message: "Lucid closed before the request finished.")
}

/// The engine half of Vivid's Lucid bridge: one mpv context, its event loop,
/// requests and ordered delivery to the adapter. UIKit lives in the core.
///
/// mpv's wakeups drain events on `eventQueue`, which also makes every
/// blocking mpv call and queues the context's destruction. Every delegate
/// callback and request completion reaches main through one async hop. A
/// bare instance does nothing until used, so tests and the subtitle probe can
/// create and drop one on any thread.
class VividPlayerCoreBase: NSObject {
    weak var delegate: VividPlayerCoreDelegate?

    let eventQueue = DispatchQueue(label: "mpv", qos: .userInitiated)
    let displayCriteria = VividPlayerDisplayCriteria()
    let pauseTracker = VividPlayerPauseTracker()
    private let requests = VividPlayerRequestTable()

    /// Whether the core can still talk to mpv. Checked together with every use
    /// of the handle, so disposal cannot slip between the check and the call.
    private struct Liveness {
        var terminal = false
        var backgrounded = false
        var handle: OpaquePointer?
        var relay: UnsafeMutableRawPointer?
    }

    private let livenessLock = NSLock()
    private var liveness = Liveness()

    private struct PendingProperty {
        let name: String
        let value: Any?
        let sourceId: Int64?
    }

    private struct PropertyCoalescing {
        var pending: [PendingProperty] = []
        /// The one queued flush allowed to deliver `pending`.
        var scheduledFlush: UInt64?
        var lastFlush: UInt64 = 0
    }

    private let coalescingLock = NSLock()
    private var coalescing = PropertyCoalescing()

    /// The playlist entry of the current file. Event queue only.
    private var currentSourceId: Int64?

    /// Properties that change on almost every presented frame. A busy main
    /// thread gets their latest values once instead of a backlog.
    private static let coalescedProperties: Set<String> = [
        "time-pos", "avsync", "demuxer-cache-state", "demuxer-cache-duration",
    ]
    private static let backgroundProperties: Set<String> = [
        "duration", "eof-reached", "pause", "paused-for-cache", "seekable", "time-pos",
    ]
    /// The bridge's own observations, with reply userdata 1 to 10. They feed
    /// the display caches only; `container-fps` also reaches the adapter
    /// through its own observation, which uses 0.
    private static let internalObservations: [(name: String, format: mpv_format)] = [
        ("container-fps", MPV_FORMAT_DOUBLE),
        ("current-tracks/video/dolby-vision-level", MPV_FORMAT_INT64),
        ("current-tracks/video/dolby-vision-profile", MPV_FORMAT_INT64),
        ("deinterlace-active", MPV_FORMAT_FLAG),
        ("height", MPV_FORMAT_DOUBLE),
        ("video-params/colormatrix", MPV_FORMAT_STRING),
        ("video-params/gamma", MPV_FORMAT_STRING),
        ("video-params/primaries", MPV_FORMAT_STRING),
        ("video-params/sig-peak", MPV_FORMAT_DOUBLE),
        ("width", MPV_FORMAT_DOUBLE),
    ]
    private static let internalObservationIDs = UInt64(1)...UInt64(internalObservations.count)

    override init() {
        super.init()
    }

    // MARK: Hooks

    /// Platform options, set after the bridge's own and before `mpv_initialize`,
    /// so they take precedence.
    func configurePlatformMpvOptions(mpv: OpaquePointer) {}

    /// Whether to choose the audio track in mpv's `on_preloaded` hook. There
    /// the file's tracks are known, but mpv has not yet made its own default
    /// pick or run the initial seek, so a resume seeks once on the chosen
    /// track. Switching after `file-loaded` makes mpv seek a second time.
    var selectsAudioWhilePreloading: Bool { false }

    /// The mpv `aid` to select while preloading, from the file's `track-list`.
    /// Nil keeps mpv's own pick. Runs on the event queue while mpv waits.
    func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64? { nil }

    /// Whether a video reconfiguration may start Match Content before playback restarts.
    var preparesDisplayCriteriaEarly: Bool { false }

    /// The platform display write. Main thread, with the source-transition lock
    /// held. Returns whether suitable criteria are in effect afterwards.
    func commitDisplayCriteria(_ request: VividPlayerDisplayCriteria.Request) -> Bool { false }

    /// Main thread.
    func applyExtendedDynamicRange(signalPeak: Double) {}

    // MARK: Liveness

    var isTerminal: Bool {
        livenessLock.lock(); defer { livenessLock.unlock() }
        return liveness.terminal
    }

    var isBackgrounded: Bool {
        livenessLock.lock(); defer { livenessLock.unlock() }
        return liveness.backgrounded
    }

    func setBackgrounded(_ backgrounded: Bool) {
        livenessLock.lock(); defer { livenessLock.unlock() }
        liveness.backgrounded = backgrounded
    }

    /// Makes the core terminal: later requests fail, queued deliveries are
    /// dropped and drains stop. Destroys nothing. False if already terminal.
    @discardableResult
    func beginDisposal() -> Bool {
        livenessLock.lock(); defer { livenessLock.unlock() }
        guard !liveness.terminal else { return false }
        liveness.terminal = true
        return true
    }

    /// Runs a non-blocking mpv call with the live handle, under the liveness
    /// lock so it cannot race the handle's destruction.
    private func withLiveHandle<T>(_ call: (OpaquePointer) -> T) -> T? {
        livenessLock.lock(); defer { livenessLock.unlock() }
        guard !liveness.terminal, let handle = liveness.handle else { return nil }
        return call(handle)
    }

    /// The live handle for a call that can block. Lucid's video output can
    /// wait on main, and main takes the liveness lock, so the call runs
    /// without it. Destruction is queued on this same queue, so the handle
    /// stays valid for the call.
    private func handleForEventQueue() -> OpaquePointer? {
        dispatchPrecondition(condition: .onQueue(eventQueue))
        livenessLock.lock(); defer { livenessLock.unlock() }
        return liveness.terminal ? nil : liveness.handle
    }

    // MARK: Context

    /// Creates the mpv context drawing into the layer at `wid`, configures it
    /// and publishes it. Main thread, inside `initialize`.
    func startContext(wid: Int64) -> Bool {
        guard let handle = mpv_create() else {
            print("[VividPlayerCore] Could not create an mpv context.")
            return false
        }
        checkError(mpv_request_log_messages(handle, "warn"))
        var wid = wid
        checkError(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))
        for (name, value) in Self.engineOptions {
            checkError(mpv_set_option_string(handle, name, value))
        }
        configurePlatformMpvOptions(mpv: handle)
        let status = mpv_initialize(handle)
        guard status >= 0 else {
            print("[VividPlayerCore] mpv could not initialise: \(VividPlayerMPVConversion.errorText(status))")
            // No video output exists yet, so this context can go at once.
            mpv_terminate_destroy(handle)
            return false
        }

        // A disposal running alongside sees either no handle, or the handle
        // together with its wakeup callback.
        let relay = Unmanaged.passRetained(VividPlayerWakeupRelay(core: self)).toOpaque()
        livenessLock.lock()
        let published = !liveness.terminal && liveness.handle == nil
        if published {
            liveness.handle = handle
            liveness.relay = relay
            mpv_set_wakeup_callback(handle, { relay in
                guard let relay else { return }
                Unmanaged<VividPlayerWakeupRelay>.fromOpaque(relay).takeUnretainedValue().scheduleDrain()
            }, relay)
        }
        livenessLock.unlock()
        guard published else {
            mpv_terminate_destroy(handle)
            Unmanaged<VividPlayerWakeupRelay>.fromOpaque(relay).release()
            return false
        }

        let selectsAudio = selectsAudioWhilePreloading
        return withLiveHandle { handle in
            for (index, observation) in Self.internalObservations.enumerated() {
                _ = mpv_observe_property(handle, UInt64(index + 1), observation.name, observation.format)
            }
            if selectsAudio {
                checkError(mpv_hook_add(handle, 0, "on_preloaded", 0))
            }
            return true
        } ?? false
    }

    private static var engineOptions: [(String, String)] {
        var options = [
            ("vo", "avfoundation"),
            // Subtitles stay on Lucid's own layer, out of the per-frame video path.
            ("avfoundation-composite-osd", "no"),
            ("hwdec-codecs", "all"),
            ("hwdec-software-fallback", "yes"),
            ("target-colorspace-hint", "auto"),
            // The last frame stays on screen under Next Up at the end of a file.
            ("keep-open", "yes"),
        ]
        #if targetEnvironment(simulator)
        options.append(("hwdec", "no"))
        #else
        options.append(("hwdec", "videotoolbox"))
        #if os(tvOS)
        options.append(("avfoundation-presentation", "host"))
        #endif
        #endif
        return options
    }

    /// Disposal's engine half: fails pending requests, holds the display,
    /// detaches the wakeup relay and queues mpv's destruction. Everything it
    /// queues captures plain values only, because it can run in `deinit`.
    func shutDownEngine(completion: (@Sendable () -> Void)?) {
        let pending = requests.takeAll()
        if !pending.isEmpty {
            let error = VividPlayerCoreError.disposed
            DispatchQueue.main.async {
                for request in pending { request.fail(with: error) }
            }
        }
        displayCriteria.resetForDisposal()

        livenessLock.lock()
        liveness.terminal = true
        let handle = liveness.handle
        let relay = liveness.relay
        liveness.handle = nil
        liveness.relay = nil
        livenessLock.unlock()
        if let relay {
            Unmanaged<VividPlayerWakeupRelay>.fromOpaque(relay).takeUnretainedValue().detach()
        }

        // Drains already queued finish first; later ones find no handle.
        eventQueue.async {
            if let handle {
                mpv_set_wakeup_callback(handle, nil, nil)
                mpv_terminate_destroy(handle)
            }
            if let relay {
                Unmanaged<VividPlayerWakeupRelay>.fromOpaque(relay).release()
            }
            completion?()
        }
    }

    /// Logs a failed mpv call with where it came from, and the option name
    /// when one is given, so a rejected option can be identified from the log.
    func checkError(_ status: CInt, option: String? = nil, file: StaticString = #fileID, line: UInt = #line) {
        guard status < 0 else { return }
        let detail = option.map { " option=\($0)" } ?? ""
        print("[VividPlayerCore] MPV error: \(VividPlayerMPVConversion.errorText(status))\(detail) at \(file):\(line)")
    }

    func convertNode(_ node: mpv_node) -> Any? {
        VividPlayerMPVConversion.value(of: node)
    }

    // MARK: Requests

    func setLogLevel(_ level: String) {
        _ = withLiveHandle { mpv_request_log_messages($0, level) }
    }

    /// Unknown formats, including `int64`, observe nothing.
    func observeProperty(_ name: String, format: String) {
        let mpvFormat: mpv_format
        switch format {
        case "double": mpvFormat = MPV_FORMAT_DOUBLE
        case "flag": mpvFormat = MPV_FORMAT_FLAG
        case "node": mpvFormat = MPV_FORMAT_NODE
        case "string": mpvFormat = MPV_FORMAT_STRING
        default: return
        }
        _ = withLiveHandle { mpv_observe_property($0, 0, name, mpvFormat) }
    }

    func command(_ args: [String]) {
        commandAsync(args) { _ in }
    }

    /// Completes with the new playlist entry's id for `loadfile`, nil otherwise.
    func commandAsync(_ args: [String], completion: @escaping (Result<Int64?, Error>) -> Void) {
        guard !args.isEmpty else {
            Self.completeOnMain { completion(.success(nil)) }
            return
        }
        // mpv copies the arguments during the call.
        let arguments = args.map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = arguments.map { $0.map { UnsafePointer($0) } } + [nil]
        submit(.command(completion)) { handle, number in
            pointers.withUnsafeMutableBufferPointer { mpv_command_async(handle, number, $0.baseAddress) }
        }
    }

    func setProperty(_ name: String, value: String) {
        setPropertyAsync(name, value: value) { _ in }
    }

    func setPropertyAsync(_ name: String, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isTerminal else {
            Self.completeOnMain { completion(.failure(VividPlayerCoreError.notAvailable)) }
            return
        }
        var finish = completion
        if name == "pause" {
            let ticket = pauseTracker.begin(paused: VividPlayerPauseTracker.isPausedValue(value))
            finish = { [weak self] result in
                if case .success = result {
                    self?.pauseTracker.resolve(ticket, succeeded: true)
                } else {
                    self?.pauseTracker.resolve(ticket, succeeded: false)
                }
                completion(result)
            }
        }
        submit(.set(finish)) { handle, number in
            name.withCString { name in
                value.withCString { value in
                    var string: UnsafePointer<CChar>? = value
                    return mpv_set_property_async(handle, number, name, MPV_FORMAT_STRING, &string)
                }
            }
        }
    }

    /// Completes with the property as a string; callers parse numbers themselves.
    func getPropertyAsync(_ name: String, completion: @escaping (Result<String?, Error>) -> Void) {
        guard !isTerminal else {
            Self.completeOnMain { completion(.failure(VividPlayerCoreError.notAvailable)) }
            return
        }
        submit(.get(completion)) { handle, number in
            mpv_get_property_async(handle, number, name, MPV_FORMAT_STRING)
        }
    }

    /// Registers and submits a request in one liveness check, so it either
    /// reaches mpv or fails, and is never missed by disposal.
    private func submit(_ request: VividPlayerRequestTable.Request, send: (OpaquePointer, UInt64) -> CInt) {
        let submission: (number: UInt64, status: CInt)? = withLiveHandle { handle in
            let number = requests.register(request)
            return (number, send(handle, number))
        }
        guard let submission else {
            Self.completeOnMain { request.fail(with: VividPlayerCoreError.notAvailable) }
            return
        }
        guard submission.status < 0, let rejected = requests.take(submission.number) else { return }
        let error = VividPlayerMPVConversion.error(submission.status)
        DispatchQueue.main.async { rejected.fail(with: error) }
    }

    private static func completeOnMain(_ completion: @escaping () -> Void) {
        if Thread.isMainThread {
            completion()
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: Events (event queue)

    fileprivate func drainEvents() {
        while let handle = handleForEventQueue(), let event = mpv_wait_event(handle, 0),
              event.pointee.event_id != MPV_EVENT_NONE {
            handleEvent(event.pointee)
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.load(as: mpv_event_property.self),
                  let name = property.name else { return }
            processPropertyChange(
                name: VividPlayerMPVConversion.string(name),
                value: VividPlayerMPVConversion.propertyValue(format: property.format, data: property.data),
                observation: event.reply_userdata, sourceId: currentSourceId)
        case MPV_EVENT_SET_PROPERTY_REPLY, MPV_EVENT_GET_PROPERTY_REPLY, MPV_EVENT_COMMAND_REPLY:
            completeRequest(event)
        case MPV_EVENT_START_FILE:
            // Held before anything for the new file can reach the display.
            holdDisplayCriteria(startingFile: true)
            if let start = event.data?.load(as: mpv_event_start_file.self) {
                currentSourceId = start.playlist_entry_id
                dispatchDelegateEvent(name: "start-file", data: nil, sourceId: start.playlist_entry_id)
            } else {
                currentSourceId = nil
                dispatchDelegateEvent(name: "start-file", data: nil)
            }
        case MPV_EVENT_FILE_LOADED:
            dispatchDelegateEvent(name: "file-loaded", data: nil, sourceId: currentSourceId)
        case MPV_EVENT_END_FILE:
            holdDisplayCriteria(startingFile: false)
            guard let end = event.data?.load(as: mpv_event_end_file.self) else {
                dispatchDelegateEvent(name: "end-file", data: nil)
                return
            }
            var data: [String: Any] = ["reason": Int(end.reason.rawValue)]
            if end.reason == MPV_END_FILE_REASON_ERROR {
                data["error"] = Int(end.error)
                data["message"] = VividPlayerMPVConversion.errorText(end.error)
            }
            dispatchDelegateEvent(name: "end-file", data: data, sourceId: end.playlist_entry_id)
        case MPV_EVENT_HOOK:
            guard let hook = event.data?.load(as: mpv_event_hook.self) else { return }
            if let name = hook.name, VividPlayerMPVConversion.string(name) == "on_preloaded" {
                selectAudioWhilePreloading()
            }
            // mpv waits for every hook to be continued, so always continue.
            _ = withLiveHandle { mpv_hook_continue($0, hook.id) }
        case MPV_EVENT_VIDEO_RECONFIG:
            prepareEarlyDisplayCriteria()
        case MPV_EVENT_PLAYBACK_RESTART:
            takeRestartSnapshot()
        case MPV_EVENT_LOG_MESSAGE:
            guard !isBackgrounded, let message = event.data?.load(as: mpv_event_log_message.self) else { return }
            dispatchDelegateEvent(name: "log-message", data: [
                "prefix": message.prefix.map(VividPlayerMPVConversion.string) ?? "",
                "level": message.level.map(VividPlayerMPVConversion.string) ?? "",
                "text": message.text.map(VividPlayerMPVConversion.string) ?? "",
            ])
        default:
            break
        }
    }

    /// Updates the bridge's own state from every change, then delivers it
    /// unless it is an internal observation or the app is in the background.
    private func processPropertyChange(name: String, value: Any?, observation: UInt64, sourceId: Int64?) {
        let effect = displayCriteria.observe(name: name, value: value)
        if let peak = effect.signalPeak {
            // This hop keeps the core alive until it runs.
            DispatchQueue.main.async { self.applyExtendedDynamicRange(signalPeak: peak) }
        }
        if effect.schedulesApply { scheduleCachedDisplayApply() }
        if name == "pause", let paused = value as? Bool { pauseTracker.observe(paused: paused) }

        if Self.internalObservationIDs.contains(observation) { return }
        if isBackgrounded, !Self.backgroundProperties.contains(name) { return }
        dispatchDelegateProperty(name: name, value: value, sourceId: sourceId)
    }

    private func completeRequest(_ event: mpv_event) {
        guard let request = requests.take(event.reply_userdata) else { return }
        let failure: Error? = event.error < 0 ? VividPlayerMPVConversion.error(event.error) : nil
        switch (event.event_id, request) {
        case (MPV_EVENT_SET_PROPERTY_REPLY, .set(let completion)):
            let result: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
            DispatchQueue.main.async { completion(result) }
        case (MPV_EVENT_GET_PROPERTY_REPLY, .get(let completion)):
            let result: Result<String?, Error> = failure.map { .failure($0) } ?? .success(Self.replyString(event.data))
            DispatchQueue.main.async { completion(result) }
        case (MPV_EVENT_COMMAND_REPLY, .command(let completion)):
            // The result is freed by the next mpv_wait_event, so read it now.
            let result: Result<Int64?, Error> = failure.map { .failure($0) } ?? .success(Self.playlistEntryID(event.data))
            DispatchQueue.main.async { completion(result) }
        default:
            break
        }
    }

    private static func replyString(_ data: UnsafeMutableRawPointer?) -> String? {
        guard let property = data?.load(as: mpv_event_property.self), property.format == MPV_FORMAT_STRING,
              let value = property.data, let pointer = value.load(as: UnsafePointer<CChar>?.self) else { return nil }
        return VividPlayerMPVConversion.string(pointer)
    }

    private static func playlistEntryID(_ data: UnsafeMutableRawPointer?) -> Int64? {
        guard let result = data?.load(as: mpv_event_command.self).result, result.format == MPV_FORMAT_NODE_MAP,
              let list = result.u.list?.pointee, list.num > 0,
              let keys = list.keys, let values = list.values else { return nil }
        for index in 0..<Int(list.num) {
            guard let key = keys[index], strcmp(key, "playlist_entry_id") == 0 else { continue }
            return values[index].format == MPV_FORMAT_INT64 ? values[index].u.int64 : nil
        }
        return nil
    }

    // MARK: Synchronous reads (event queue)

    /// Nil when unavailable or not finite.
    func readDoubleProperty(_ name: String) -> Double? {
        guard let handle = handleForEventQueue() else { return nil }
        var value = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
        return value
    }

    func readFlagProperty(_ name: String) -> Bool? {
        guard let handle = handleForEventQueue() else { return nil }
        var value: CInt = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    func readMapProperty(_ name: String) -> [String: Any]? {
        readNodeProperty(name) as? [String: Any]
    }

    /// Nil unless every element is a map.
    func readMapListProperty(_ name: String) -> [[String: Any]]? {
        readNodeProperty(name) as? [[String: Any]]
    }

    private func readNodeProperty(_ name: String) -> Any? {
        guard let handle = handleForEventQueue() else { return nil }
        var node = mpv_node()
        guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return VividPlayerMPVConversion.value(of: node)
    }

    /// Before mpv's default track pick, an `aid` set here is the selection mpv
    /// starts with, rather than a switch that needs another seek.
    private func selectAudioWhilePreloading() {
        guard let tracks = readMapListProperty("track-list"),
              let id = preloadedAudioTrackID(tracks: tracks),
              let handle = handleForEventQueue() else { return }
        checkError(mpv_set_property_string(handle, "aid", String(id)), option: "aid")
    }

    // MARK: Display criteria (event queue)

    // Internal so tests can drive them with the synchronous reads and the
    // platform write overridden, without an mpv context.

    func holdDisplayCriteria(startingFile: Bool) {
        #if VIVID_P8_TRIAL
        if let timing = displayCriteria.holdForSourceTransition(startingFile: startingFile) {
            // Measured on the event queue; main-queue delivery time is not lock wait.
            dispatchDelegateEvent(name: "display-commit-lock", data: [
                "transition": startingFile ? "start_file" : "end_file",
                "wait_ms": timing.waitMs,
                "held_ms": timing.heldMs,
            ])
        }
        #else
        displayCriteria.holdForSourceTransition(startingFile: startingFile)
        #endif
    }

    /// Playback restart, after a load or a seek, is the authoritative snapshot.
    /// Changes for the new file can still be queued behind this event, so the
    /// stream is read now rather than taken from the caches.
    func takeRestartSnapshot() {
        let readings = VividPlayerDisplayCriteria.Readings(
            measuredFps: readDoubleProperty("estimated-vf-fps"),
            containerFps: readDoubleProperty("container-fps"),
            deinterlaced: readFlagProperty("deinterlace-active"),
            videoParams: readMapProperty("video-params"),
            videoTrack: readMapProperty("current-tracks/video"))
        displayCriteria.applyRestartSnapshot(readings)
        // Queued ahead of the restart, so the HDMI decision lands first.
        scheduleCachedDisplayApply()
        let position = readDoubleProperty("time-pos")
        dispatchDelegateEvent(name: "playback-restart",
                              data: position.map { ["positionSeconds": $0] as [String: Any] },
                              sourceId: currentSourceId)
    }

    /// A decoded video output can be configured before audio is ready. Start
    /// Match Content from the first complete snapshot then, without pausing
    /// either stream. The hold stays until playback restart reconciles the
    /// final cadence, so partial observer updates cannot change the mode.
    func prepareEarlyDisplayCriteria() {
        guard preparesDisplayCriteriaEarly, let epoch = displayCriteria.earlySnapshotEpoch() else { return }
        guard let output = readMapProperty("video-out-params"),
              let track = readMapProperty("current-tracks/video"),
              let width = output["w"] as? Int64, let height = output["h"] as? Int64,
              VividPlayerMPVConversion.dimensionsAreAcceptable(width, height),
              let containerFps = readDoubleProperty("container-fps"), containerFps > 0,
              let measuredFps = readDoubleProperty("estimated-vf-fps"), measuredFps > 0,
              let deinterlaced = readFlagProperty("deinterlace-active") else { return }
        let request = VividPlayerDisplayCriteria.earlyRequest(
            outputParams: output, videoTrack: track, width: width, height: height,
            containerFps: containerFps, measuredFps: measuredFps, deinterlaced: deinterlaced)
        displayCriteria.finishEarlySnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminal else { return }
            self.displayCriteria.commitEarly(request, epoch: epoch, write: self.commitDisplayCriteria) {
                self.delegate?.onEvent(name: "display-criteria-prepared", data: nil)
            }
        }
    }

    /// Merges observer changes into one main-thread write. It has no disposal
    /// check of its own: disposal sets the hold, which it respects.
    private func scheduleCachedDisplayApply() {
        guard displayCriteria.markApplyScheduled() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayCriteria.runCachedApply { _ = self.commitDisplayCriteria($0) }
        }
    }

    // MARK: Ordered delivery

    /// Delivers on main in mpv's order. The four per-frame properties merge
    /// while main is busy, and every other delivery carries any pending ones
    /// ahead of itself.
    func dispatchDelegateProperty(name: String, value: Any?, sourceId: Int64?) {
        let property = PendingProperty(name: name, value: value, sourceId: sourceId)
        guard Self.coalescedProperties.contains(name) else {
            let pending = takePendingCoalescedProperties()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminal else { return }
                self.deliver(pending + [property])
            }
            return
        }

        coalescingLock.lock()
        if let index = coalescing.pending.firstIndex(where: { $0.name == name }) {
            coalescing.pending[index] = property
        } else {
            coalescing.pending.append(property)
        }
        var flush: UInt64?
        if coalescing.scheduledFlush == nil {
            coalescing.lastFlush &+= 1
            coalescing.scheduledFlush = coalescing.lastFlush
            flush = coalescing.lastFlush
        }
        coalescingLock.unlock()

        guard let flush else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coalescingLock.lock()
            guard self.coalescing.scheduledFlush == flush else {
                // A later delivery already carried these values in order.
                self.coalescingLock.unlock()
                return
            }
            let pending = self.coalescing.pending
            self.coalescing.pending = []
            self.coalescing.scheduledFlush = nil
            self.coalescingLock.unlock()
            guard !self.isTerminal else { return }
            self.deliver(pending)
        }
    }

    /// With a source id, the payload gains `sourceId`; without one it passes
    /// through unchanged.
    func dispatchDelegateEvent(name: String, data: [String: Any]?, sourceId: Int64? = nil) {
        var payload = data
        if let sourceId {
            var withSource = data ?? [:]
            withSource["sourceId"] = sourceId
            payload = withSource
        }
        let pending = takePendingCoalescedProperties()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminal else { return }
            self.deliver(pending)
            self.delegate?.onEvent(name: name, data: payload)
        }
    }

    private func takePendingCoalescedProperties() -> [PendingProperty] {
        coalescingLock.lock(); defer { coalescingLock.unlock() }
        let pending = coalescing.pending
        coalescing.pending = []
        coalescing.scheduledFlush = nil
        return pending
    }

    private func deliver(_ properties: [PendingProperty]) {
        for property in properties {
            delegate?.onPropertyChange(name: property.name, value: property.value, sourceId: property.sourceId)
        }
    }
}

/// mpv's wakeup callback target. It holds the core weakly and only queues a
/// drain, which is all mpv allows on its own threads.
private final class VividPlayerWakeupRelay {
    private let lock = NSLock()
    private weak var core: VividPlayerCoreBase?

    init(core: VividPlayerCoreBase) {
        self.core = core
    }

    func scheduleDrain() {
        lock.lock()
        let target = core
        target?.eventQueue.async { [weak target] in target?.drainEvents() }
        lock.unlock()
        // A core nobody disposed can be released right here. Its deinit
        // detaches this relay, so it must run after the unlock.
        withExtendedLifetime(target) {}
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        core = nil
    }
}
#endif
