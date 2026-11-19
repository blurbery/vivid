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
    func shutdown() async
}

extension KeyframeStillReader: KeyframeStillReading {}

/// A reader opened for one load, with the length of the file it reads.
struct KeyframeStillSource: Sendable {
    let reader: any KeyframeStillReading
    /// Nil until the length is known.
    let fileSize: @Sendable () -> Int64?
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
    /// The hidden switch. Off unless set, for example with the launch
    /// argument `-vivid.debug.keyframeStills YES`.
    static let switchKey = "vivid.debug.keyframeStills"

    /// What the service reads from the player. It never writes any of it.
    struct PlayerState: Equatable {
        /// Why playback isn't settled just now.
        enum Unsettled: String {
            case buffering, loading, seeking, replanning, recovering, changingQuality, ended
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
        var isEnabled: @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: KeyframeStillService.switchKey) }
        var machineIdentifier = AppleDecodeCapabilities.machineIdentifier
        var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// Runs off the main actor. Nil when the address can't be read.
        var open: @Sendable (URL, KeyframeStillHeaders) -> KeyframeStillSource? = KeyframeStillService.openSource
        var makeNetworkWatch: @MainActor () -> KeyframeStillNetworkWatch = { KeyframeStillPathWatch() }
        /// False in tests, which call `tick()` themselves.
        var startsTicker = true
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
        case loadEnded, switchedOff, background, cannotOpen, cannotProduceStills, noKeyframeIndex, refused

        /// True when asking again for the same load could never help.
        var rulesOutTheLoad: Bool {
            switch self {
            case .loadEnded, .background: false
            case .switchedOff, .cannotOpen, .cannotProduceStills, .noKeyframeIndex, .refused: true
            }
        }
    }

    /// What read-ahead has already spent on a file, kept across a reload of
    /// the same file so the budget is per title and not per load.
    struct Carry: Equatable {
        let key: String
        let readAheadBytes: Int
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
        static let healthyBufferSeconds: Double = 20
        /// One preview interval: how far before the target a still may be.
        static let window: Double = 10
        /// While the target moves fast the window grows to what it covers
        /// in this long, up to `widestWindow`.
        static let glanceSeconds: Double = 0.2
        static let widestWindow: Double = 120
        /// A rate of change older than this says nothing about now.
        static let rateHoldSeconds: TimeInterval = 0.5
        static let nearSpanSeconds: Double = 120
        /// The sparse ladder across the title: every five minutes, then the
        /// points halfway between.
        static let ladder: [(step: Double, offset: Double)] = [(300, 0), (300, 150)]
        static let ladderPauseSeconds: TimeInterval = 2
        static let remoteBudgetFraction: Int64 = 100
        static let remoteBudgetLimit: Int64 = 60 * 1024 * 1024
        static let localBudgetFraction: Int64 = 50
        static let idleDecoderSeconds: TimeInterval = 3
        static let burstGapSeconds: TimeInterval = 3
        static let firstBackOffSeconds: TimeInterval = 5
        static let longestBackOffSeconds: TimeInterval = 60
        static let tickSeconds: TimeInterval = 1
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
    /// HLS, transcodes and server remuxes are something else's bytes.
    static func isOriginalFile(_ spec: VividLoadSpec) -> Bool {
        isOriginalFile(url: spec.sourceURL, delivery: spec.delivery, planID: spec.planID,
                       nativeRemoteHLS: spec.options.nativeRemoteHLS)
    }

    static func isOriginalFile(url: URL, delivery: String, planID: String, nativeRemoteHLS: Bool) -> Bool {
        if url.isFileURL { return true }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP,
              !nativeRemoteHLS
        else { return false }
        // Emby and Jellyfin streams all load as `legacy-direct`. Only the
        // one that asks for the stored file says `Static=true`.
        guard planID == "legacy-direct" else { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name.lowercased() == "static" && $0.value?.lowercased() == "true" }
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

    nonisolated static let openSource: @Sendable (URL, KeyframeStillHeaders) -> KeyframeStillSource? = { url, headers in
        let source: StillByteSource
        if url.isFileURL {
            guard let file = FileStillByteSource(url: url) else { return nil }
            source = file
        } else {
            source = HTTPStillByteSource(url: url, headers: { headers.current })
        }
        return KeyframeStillSource(reader: KeyframeStillReader(source: source), fileSize: { source.size })
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
