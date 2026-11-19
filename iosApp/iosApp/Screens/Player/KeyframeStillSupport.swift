import CoreGraphics
import Foundation
import ImageIO
import Network
import os
import UniformTypeIdentifiers

/// What the still service asks of a keyframe reader. `KeyframeStillReader`
/// is the only one in the app; tests stand in a scripted one.
protocol KeyframeStillReading: AnyObject, Sendable {
    var info: KeyframeStillInfo? { get }
    var index: [KeyframeIndexEntry] { get }
    func prepare() async -> KeyframeStillInfo?
    func result(at seconds: Double, maxWidth: Int, urgent: Bool) async -> KeyframeStillResult
    func closeDecoder()
    /// Stops whatever the reader is doing, without waiting for it: the read
    /// that is running and the one waiting both end as `.cancelled`, and an
    /// open that is running ends as nil. The reader stays usable. Safe from
    /// any thread, and never blocks on a read.
    func cancel()
    func shutdown() async
}

extension KeyframeStillReader: KeyframeStillReading {}

/// Where the provider gets the service's view of the player, asked for
/// only once the hidden switch is known to be on.
@MainActor
protocol KeyframeStillPlayerSource: AnyObject {
    var keyframeStillPlayer: KeyframeStillService.Player { get }
}

/// A reader opened for one load, with the length of the file it reads.
struct KeyframeStillSource: Sendable {
    let reader: any KeyframeStillReading
    /// Nil until the length is known.
    let fileSize: @Sendable () -> Int64?
    /// Every byte the source has fetched so far, which for a server is more
    /// than the reader was handed: a request brings a whole block. Nil for
    /// a source where the two are the same, such as a file on the device.
    var receivedBytes: (@Sendable () -> Int)?
}

/// The request headers the byte source sends. The service copies the
/// load's current headers in before every read, so a token the player has
/// refreshed since is the one that goes out.
final class KeyframeStillHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: String] = [:]

    var current: [String: String] {
        get { lock.withLock { fields } }
        set { lock.withLock { fields = newValue } }
    }
}

/// Whether the network may be used for stills nobody is waiting on.
protocol KeyframeStillNetworkWatch: AnyObject {
    /// False on mobile data, on a path the system marks as constrained, and
    /// until the first path is known.
    var allowsReadAhead: Bool { get }
    func cancel()
}

final class KeyframeStillPathWatch: KeyframeStillNetworkWatch, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var allowed = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            self?.lock.withLock { self?.allowed = allowed }
        }
        monitor.start(queue: DispatchQueue(label: "vivid.keyframe-stills.path", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    var allowsReadAhead: Bool { lock.withLock { allowed } }

    func cancel() {
        monitor.cancel()
    }
}

extension KeyframeStillService {
    /// The hidden switch. On unless it's set to false, for example with the
    /// launch argument `-vivid.debug.keyframeStills NO`, which turns the
    /// keyframe stills off to rule them out when chasing a problem.
    static let switchKey = "vivid.debug.keyframeStills"

    static func isSwitchedOn() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: switchKey) != nil else { return true }
        return defaults.bool(forKey: switchKey)
    }

    /// What the service reads from the player. It never writes any of it.
    struct PlayerState: Equatable {
        /// Why playback isn't settled just now.
        enum Unsettled: String {
            case buffering, loading, seeking, replanning, recovering, changingQuality, failed, ended

            /// False only for seeking, which a scrub itself reports: the
            /// viewer's own reads go on through it. Everything else stops
            /// every read, the viewer's included.
            var stopsViewerReads: Bool { self != .seeking }
        }

        /// The playhead, in source-media time.
        var sourceTime: Double
        var isPlaying: Bool
        var unsettled: Unsettled?
        /// How far ahead the player has read. Nil when the route doesn't
        /// measure it.
        var bufferedAheadSeconds: Double?
        var isAppActive = true
        /// An AirPlay receiver or Picture in Picture has the picture.
        var isHandedOff = false
        /// Nil until the player says how it decodes.
        var decodesInSoftware: Bool?
        var droppedFrames: Int?
        var avSyncGapMilliseconds: Double?
    }

    /// What the view model publishes, as plain values, so turning it into
    /// a `PlayerState` is a pure function that tests can call.
    struct PlayerSnapshot: Equatable {
        var sourceTime: Double = 0
        var isPlaying = false
        var hasError = false
        var hasReachedEnd = false
        var isReplanning = false
        var isRecovering = false
        var isChangingQuality = false
        var isSeeking = false
        var isLoading = false
        var isBuffering = false
        var bufferedAheadSeconds: Double?
        var isAppActive = true
        var isAirPlayHandOff = false
        /// Only ever true on iPhone and iPad: Apple TV has no Picture in
        /// Picture of its own to read.
        var isPictureInPicture = false
        /// The engine's name for the decoder in use. Nil until it says.
        var videoDecoder: String?
        var droppedFrames: Int?
        var avSyncGapMilliseconds: Double?
    }

    /// The player's published state as the service reads it. When several
    /// things are going on at once the gravest is the one reported.
    nonisolated static func playerState(from snapshot: PlayerSnapshot) -> PlayerState {
        var unsettled: PlayerState.Unsettled?
        if snapshot.hasError {
            unsettled = .failed
        } else if snapshot.hasReachedEnd {
            unsettled = .ended
        } else if snapshot.isReplanning {
            unsettled = .replanning
        } else if snapshot.isRecovering {
            unsettled = .recovering
        } else if snapshot.isChangingQuality {
            unsettled = .changingQuality
        } else if snapshot.isSeeking {
            unsettled = .seeking
        } else if snapshot.isLoading {
            unsettled = .loading
        } else if snapshot.isBuffering {
            unsettled = .buffering
        }
        return PlayerState(
            sourceTime: snapshot.sourceTime,
            isPlaying: snapshot.isPlaying,
            unsettled: unsettled,
            bufferedAheadSeconds: snapshot.bufferedAheadSeconds,
            isAppActive: snapshot.isAppActive,
            isHandedOff: snapshot.isAirPlayHandOff || snapshot.isPictureInPicture,
            // Anything other than VideoToolbox is decoding on the processor.
            decodesInSoftware: snapshot.videoDecoder.map { !$0.lowercased().contains("videotoolbox") },
            droppedFrames: snapshot.droppedFrames,
            avSyncGapMilliseconds: snapshot.avSyncGapMilliseconds)
    }

    /// The service's view of the player, asked afresh every time.
    struct Player {
        /// Nil when the load the service was made for is no longer the one
        /// playing.
        let state: @MainActor () -> PlayerState?
        /// The headers the load's source takes right now. Nil when that
        /// address is no longer the one loaded.
        let headers: @MainActor (URL) -> [String: String]?
    }

    /// Everything the service takes from outside, so tests can stand in for
    /// each part.
    struct Environment {
        var isEnabled: @MainActor () -> Bool = { KeyframeStillService.isSwitchedOn() }
        var machineIdentifier = AppleDecodeCapabilities.machineIdentifier
        var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Runs off the main actor. Nil when the address can't be read.
        var open: @Sendable (URL, KeyframeStillHeaders) -> KeyframeStillSource? = KeyframeStillService.openSource
        var makeNetworkWatch: @MainActor () -> KeyframeStillNetworkWatch = { KeyframeStillPathWatch() }
        /// False in tests, which call `tick()` themselves.
        var startsTicker = true
        /// The wait before a fast-moving target's wide window is looked at
        /// again. Tests stand in their own.
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
        var notifications = NotificationCenter.default
        /// Tests read the measurement lines here. Nil writes them to the
        /// unified log.
        var record: (@MainActor (String) -> Void)?
    }

    /// Why a load gets no still service.
    enum Gate: String {
        case switchedOff, serverSheets, notOriginalFile, audioOnly, appleTVHD, loadNotCurrent, handedOff, background
    }

    /// How a service came to its end.
    enum End: String {
        case loadEnded, switchedOff, cannotOpen, cannotProduceStills, noKeyframeIndex, badIndex, refused

        /// True when asking again for the same load could never help.
        var rulesOutTheLoad: Bool {
            switch self {
            case .loadEnded: false
            case .switchedOff, .cannotOpen, .cannotProduceStills, .noKeyframeIndex, .badIndex, .refused: true
            }
        }
    }

    /// What read-ahead has already spent on a file, kept across a reload of
    /// the same file so the budget is per title and not per load.
    struct Carry: Equatable {
        let key: String
        let readAheadBytes: Int
        /// The part of it spent near the playhead.
        var nearBytes = 0
    }

    enum Tuning {
        #if os(tvOS)
        static let stillWidth = 320
        static let encodedByteLimit = 8 * 1024 * 1024
        #else
        static let stillWidth = 480
        static let encodedByteLimit = 16 * 1024 * 1024
        #endif
        static let decodedLimit = 6
        /// Playback this steady before a reader may exist.
        static let steadyPlaySeconds: TimeInterval = 5
        /// Read-ahead starts once the player has this much buffered ahead,
        /// and stops when it falls below `lowBufferSeconds`. The gap keeps
        /// a buffer hovering at one figure from starting and stopping it.
        static let healthyBufferSeconds: Double = 30
        static let lowBufferSeconds: Double = 20
        /// One preview interval: how far before the target a still may be.
        static let window: Double = 10
        /// While the target moves fast the window grows to what it covers
        /// in this long, up to `widestWindow`.
        static let glanceSeconds: Double = 0.2
        static let widestWindow: Double = 120
        /// A rate of change older than this says nothing about now.
        static let rateHoldSeconds: TimeInterval = 0.5
        static let nearSpanSeconds: Double = 120
        /// Near the playhead one keyframe is read ahead for each stretch
        /// this long, not every keyframe.
        static let nearSlotSeconds: Double = 10
        /// The most of the budget the stills near the playhead may take,
        /// as a divisor, so the ladder across the title is always reached.
        static let nearBudgetDivisor = 2
        /// No file is longer than this. An index or a duration that says
        /// otherwise is damaged, and the file gets no stills.
        static let longestFileSeconds: Double = 24 * 60 * 60
        static let indexEntryLimit = 400_000
        /// The most entries any one walk back through the index takes.
        static let walkLimit = 64
        static let encodedCountLimit = 2_048
        /// The sparse ladder across the title: every five minutes, then the
        /// points halfway between.
        static let ladder: [(step: Double, offset: Double)] = [(300, 0), (300, 150)]
        static let ladderPauseSeconds: TimeInterval = 2
        /// The most points of one rung that are ever looked at: more than
        /// a day of them.
        static let ladderStepLimit = 300
        /// How long the ladder is left alone once every point on it has
        /// been read or can't be.
        static let ladderRestSeconds: TimeInterval = 30
        static let remoteBudgetFraction: Int64 = 100
        static let remoteBudgetLimit: Int64 = 60 * 1024 * 1024
        static let localBudgetFraction: Int64 = 50
        static let idleDecoderSeconds: TimeInterval = 3
        static let burstGapSeconds: TimeInterval = 3
        static let firstBackOffSeconds: TimeInterval = 5
        static let longestBackOffSeconds: TimeInterval = 60
        static let tickSeconds: TimeInterval = 1
        /// How often the gates are looked at while a read is out.
        static let busyTickSeconds: TimeInterval = 0.25
        static let appleTVHD = "AppleTV5,3"
    }

    /// Why this load can have no service, or nil when it can. Nothing is
    /// created to find out.
    static func gate(for spec: VividLoadSpec, hasServerSheets: Bool, state: PlayerState?,
                     environment: Environment) -> Gate? {
        guard environment.isEnabled() else { return .switchedOff }
        if hasServerSheets { return .serverSheets }
        guard isOriginalFile(spec) else { return .notOriginalFile }
        if spec.options.audioOnly { return .audioOnly }
        if environment.machineIdentifier == Tuning.appleTVHD { return .appleTVHD }
        guard let state else { return .loadNotCurrent }
        if state.isHandedOff { return .handedOff }
        guard state.isAppActive else { return .background }
        return nil
    }

    /// True for the three ways a file is played exactly as it is stored: a
    /// download, Emby or Jellyfin direct play, and Silo's `original_http`.
    /// HLS, transcodes and server remuxes are something else's bytes. The
    /// load spec says which it is from what the app itself asked for (see
    /// `VividLoadSpec.playsStoredFile`).
    static func isOriginalFile(_ spec: VividLoadSpec) -> Bool {
        spec.playsStoredFile
    }

    /// True for an address on the viewer's own network: a private or
    /// link-local address, or a name that only resolves there. Nothing is
    /// looked up.
    static func isLocalHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        if parts.count == 4, let first = parts[0], let second = parts[1], parts[2] != nil, parts[3] != nil {
            switch (first, second) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        guard host.contains(":") else { return false }
        if host == "::1" { return true }
        // fe80::/10 is link-local, fc00::/7 is unique local.
        return ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains { host.hasPrefix($0) }
    }

    /// Names a file across loads without its query, where tokens live.
    static func carryKey(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.fragment = nil
        return parts?.string ?? url.path
    }

    /// The last entry at or before `seconds`, as the reader picks it.
    nonisolated static func position(at seconds: Double, in index: [KeyframeIndexEntry]) -> Int? {
        guard seconds.isFinite else { return nil }
        let target = max(seconds, 0)
        var low = 0, high = index.count
        while low < high {
            let middle = (low + high) / 2
            if index[middle].time <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The index as the service may use it, or nil for one that can't be
    /// trusted: too many entries, or a time that isn't a number, runs
    /// backwards or lies past the longest file there could be. One pass,
    /// made off the main actor when the file opens, so that nothing later
    /// has to walk the index or trust a time in it.
    nonisolated static func usableIndex(_ entries: [KeyframeIndexEntry], duration: Double?) -> [KeyframeIndexEntry]? {
        if let duration, !(duration.isFinite && duration >= 0 && duration <= Tuning.longestFileSeconds) { return nil }
        guard entries.count <= Tuning.indexEntryLimit else { return nil }
        var last = 0.0
        for entry in entries {
            guard entry.time.isFinite, entry.time >= last, entry.time <= Tuning.longestFileSeconds else { return nil }
            last = entry.time
        }
        return entries
    }

    nonisolated static let openSource: @Sendable (URL, KeyframeStillHeaders) -> KeyframeStillSource? = { url, headers in
        if url.isFileURL {
            guard let file = FileStillByteSource(url: url) else { return nil }
            return KeyframeStillSource(reader: KeyframeStillReader(source: file), fileSize: { file.size })
        }
        let server = HTTPStillByteSource(url: url, headers: { headers.current })
        return KeyframeStillSource(reader: KeyframeStillReader(source: server), fileSize: { server.size },
                                   receivedBytes: { server.counters.bytes })
    }

    // MARK: - Held stills

    struct HeldImage: @unchecked Sendable {
        let image: CGImage
    }

    nonisolated static func encode(_ still: HeldImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, still.image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated static func decode(_ data: Data) -> HeldImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              // Decoded here, not when it is first drawn.
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return HeldImage(image: image)
    }

    static let logger = Logger(subsystem: "com.blurbery.vivid", category: "KeyframeStills")
}
