import Foundation
import Network
import OSLog

/// The app's connection state: whether the device has a network path, and
/// whether the server answers, learned from the outcome of every `HTTPClient`
/// request. Screens use it to tell cached data shown during an outage from a
/// healthy session, and playback entry points check it before opening a
/// player that can't stream.
///
/// Server status is optimistic: `.unknown` counts as reachable, so nothing is
/// blocked before a failure has been seen. Any HTTP response, a 4xx or 5xx
/// included, proves the server is up; only transport failures (refused,
/// timed out, DNS) mark it unreachable. While it's unreachable a loop probes
/// `GET /api/v1/health` every 15 seconds, so the state recovers by itself.
@MainActor
@Observable
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()

    enum ServerStatus {
        case unknown
        case reachable
        case unreachable
    }

    /// The device has a usable network path (Wi-Fi, cellular or wired).
    private(set) var isDeviceOnline = true
    private(set) var serverStatus: ServerStatus = .unknown

    /// Gate for starting server work. `.unknown` passes, so the first request
    /// after launch is never blocked.
    var isServerReachable: Bool { isDeviceOnline && serverStatus != .unreachable }

    /// Drives the offline UI: true only once a failure has been seen or the
    /// device itself is offline.
    var isOffline: Bool { !isDeviceOnline || serverStatus == .unreachable }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "ConnectionMonitor"
    )
    private static let probeSpacing: Duration = .seconds(15)

    private let pathMonitor = NWPathMonitor()
    private var hasInitialPath = false
    private var probeLoop: Task<Void, Never>?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.devicePathChanged(online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.vivid.connection-monitor"))
    }

    // MARK: - Signals from HTTPClient

    /// An HTTP response arrived, so the server is up whatever the status code.
    ///
    /// This runs after every request, so only the change to reachable is
    /// traced and reported. The health report writes to UserDefaults, and a
    /// defaults write makes iCloud preference sync re-read the server's
    /// settings, whose reply lands back here: reporting every time caused a
    /// settings request every few seconds.
    func noteServerResponded() {
        if serverStatus != .reachable {
            Self.logger.info("Server marked reachable")
            trace("server reachable", outcome: "reachable")
            AppHealthMonitor.serverReachabilityChanged(true)
        }
        serverStatus = .reachable
        stopProbing()
    }

    /// A request failed with no HTTP response. Callers don't report
    /// cancellations here. Traced once per outage, not once per failure.
    func noteServerUnreachable() {
        guard serverStatus != .unreachable else { return }
        Self.logger.info("Server marked unreachable")
        trace("server unreachable", level: .warning, outcome: "unreachable")
        serverStatus = .unreachable
        AppHealthMonitor.serverReachabilityChanged(false)
        startProbing()
    }

    // MARK: - Probing

    /// One health check. It goes through `HTTPClient`, whose outcome reporting
    /// updates `serverStatus`.
    @discardableResult
    func probeServer() async -> Bool {
        do {
            let _: HealthStatus = try await HTTPClient.shared.get("/api/v1/health")
            return true
        } catch {
            return false
        }
    }

    /// Waits, up to `timeout` seconds, for the first network path, so launch
    /// decisions (such as opening on Downloads when offline) don't read the
    /// optimistic default.
    func waitForInitialPath(timeout: TimeInterval = 1.0) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !hasInitialPath, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Internals

    /// The monitor repeats paths on interface churn (Wi-Fi roaming, a VPN
    /// reconfiguring), so only a change in whether the device is online
    /// counts. Only that boolean is traced, never the interface, SSID or
    /// anything else about the path that could reveal a location.
    private func devicePathChanged(online: Bool) {
        hasInitialPath = true
        guard online != isDeviceOnline else { return }
        isDeviceOnline = online
        AppHealthMonitor.deviceOnlineChanged(online)
        let state = online ? "online" : "offline"
        Self.logger.info("Device network path: \(state, privacy: .public)")
        trace("device network path changed", level: online ? .info : .warning, outcome: state)

        guard online else {
            stopProbing()
            return
        }
        // Probing pauses while offline, so pick it up again and check now
        // rather than waiting for the next request.
        if serverStatus == .unreachable {
            startProbing()
            Task { await self.probeServer() }
        }
    }

    /// Arming is traced once; ticks aren't. A failed probe is already traced
    /// by HTTPClient and the recovery by `noteServerResponded`.
    private func startProbing() {
        guard probeLoop == nil, isDeviceOnline else { return }
        trace("reprobe loop armed", outcome: "unreachable")
        probeLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.probeSpacing)
                guard !Task.isCancelled,
                      let self,
                      self.serverStatus == .unreachable,
                      self.isDeviceOnline
                else { return }
                await self.probeServer()
            }
        }
    }

    private func stopProbing() {
        probeLoop?.cancel()
        probeLoop = nil
    }

    private func trace(_ message: String, level: DiagnosticsLogLevel = .info, outcome: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.log(.essential, level: level, category: .network, tag: "Reach",
                      message: message, attrs: ["outcome": .string(outcome)])
        #endif
    }
}
