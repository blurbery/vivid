#if os(iOS) || os(tvOS)
import Foundation

/// A redacted crash, hang or exit record kept on this device. Nothing here is
/// uploaded: a report only leaves the device when someone shares it from
/// Settings → About → Diagnostics.
///
/// Every field is either an enum-style token, a number or redacted text. No
/// titles, item IDs, server addresses or account details are recorded.
struct AppHealthReport: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case crash
        case hang
        case cpuException = "cpu_exception"
        case diskWriteException = "disk_write_exception"
        case slowLaunch = "slow_launch"
        case unexpectedExit = "unexpected_exit"
        case playbackFailure = "playback_failure"
        case appError = "app_error"

        var title: String {
            switch self {
            case .crash: return "Crash"
            case .hang: return "Hang"
            case .cpuException: return "High CPU use"
            case .diskWriteException: return "Heavy disk writes"
            case .slowLaunch: return "Slow launch"
            case .unexpectedExit: return "Unexpected exit"
            case .playbackFailure: return "Playback failure"
            case .appError: return "App error"
            }
        }

        /// Pruning order when the store is full: app errors go first, then
        /// performance reports, so routine noise never pushes out a crash.
        var retentionPriority: Int {
            switch self {
            case .appError: return 0
            case .hang, .cpuException, .diskWriteException, .slowLaunch: return 1
            case .crash, .unexpectedExit, .playbackFailure: return 2
            }
        }
    }

    /// Where the report came from. MetricKit hangs and watchdog hangs can
    /// describe the same stall, so the source keeps them apart.
    enum Source: String, Codable {
        case metricKit = "metrickit"
        case watchdog
        case exitMarker = "exit_marker"
        case app
    }

    static let formatVersion = 1

    let format: Int
    let id: String
    let kind: Kind
    let source: Source
    let recordedAt: Date
    let app: AppHealthAppInfo
    let details: [String: DiagnosticsJSONValue]
    let context: [String: DiagnosticsJSONValue]?
    /// Allow-listed MetricKit call stack tree. Binary UUIDs and offsets are
    /// kept so the stacks can be symbolicated against the build's dSYMs.
    let callStackTree: DiagnosticsJSONValue?
    /// Recent app events before the problem, from `AppHealthTrail`.
    let recentEvents: [String]?

    init(
        kind: Kind,
        source: Source,
        recordedAt: Date,
        app: AppHealthAppInfo,
        details: [String: DiagnosticsJSONValue],
        context: [String: DiagnosticsJSONValue]? = nil,
        callStackTree: DiagnosticsJSONValue? = nil,
        recentEvents: [String]? = nil,
        fingerprintSeed: String
    ) {
        self.format = Self.formatVersion
        self.kind = kind
        self.source = source
        self.recordedAt = recordedAt
        self.app = app
        self.details = details
        self.context = context
        self.callStackTree = callStackTree
        self.recentEvents = recentEvents?.isEmpty == true ? nil : recentEvents
        // The seed identifies the underlying event, so a payload MetricKit
        // delivers twice (live and again through the past payloads) is stored
        // once.
        self.id = DiagnosticsSHA256.shortHex(
            data: Data("\(kind.rawValue)|\(source.rawValue)|\(fingerprintSeed)".utf8),
            count: 24
        )
    }
}

extension AppHealthReport {
    /// This report with MetricKit's copy of the same crash folded in: its
    /// call stack and crash details are added, and this report keeps its ID,
    /// context and recent events.
    func merging(metricKit other: AppHealthReport) -> AppHealthReport {
        AppHealthReport(
            id: id,
            kind: .crash,
            source: source,
            recordedAt: recordedAt,
            app: app,
            details: details.merging(other.details) { _, metricKit in metricKit },
            context: context,
            callStackTree: other.callStackTree,
            recentEvents: recentEvents
        )
    }

    private init(
        id: String,
        kind: Kind,
        source: Source,
        recordedAt: Date,
        app: AppHealthAppInfo,
        details: [String: DiagnosticsJSONValue],
        context: [String: DiagnosticsJSONValue]?,
        callStackTree: DiagnosticsJSONValue?,
        recentEvents: [String]?
    ) {
        self.format = Self.formatVersion
        self.id = id
        self.kind = kind
        self.source = source
        self.recordedAt = recordedAt
        self.app = app
        self.details = details
        self.context = context
        self.callStackTree = callStackTree
        self.recentEvents = recentEvents
    }
}

struct AppHealthAppInfo: Codable, Equatable {
    let version: String
    let build: String
    let os: String
    let device: String

    static let current: AppHealthAppInfo = {
        let info = Bundle.main.infoDictionary
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let platform = "tvOS"
        #else
        let platform = "iOS"
        #endif
        return AppHealthAppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            os: "\(platform) \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            device: AppHealthSystem.hardwareModel
        )
    }()
}

/// Process and device facts the monitor needs. Kept separate so tests can
/// supply their own values.
enum AppHealthSystem {
    /// The hardware model identifier, such as `iPhone16,2` or `AppleTV14,1`.
    /// It names the model, not the individual device.
    static let hardwareModel: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? "unknown" : model
    }()

    /// Wall-clock boot time in whole seconds. A different value on the next
    /// launch means the device restarted, which ends the app without a crash.
    static func bootTime() -> Int {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return 0 }
        return Int(bootTime.tv_sec)
    }

    /// True when a debugger is attached. Stopping the app from Xcode kills it
    /// in the foreground, which must not read as an unexpected exit.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
#endif
