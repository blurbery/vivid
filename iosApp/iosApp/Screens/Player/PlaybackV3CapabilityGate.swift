import Foundation

/// One Protocol V3 capability probe per server. Vivid needs the neutral plan
/// contract and header-authenticated media (credential-free URLs) before it
/// can hand a source URL to the engine. The in-flight probe is shared, so two
/// players starting together send one request.
actor PlaybackV3CapabilityGate {
    static let shared = PlaybackV3CapabilityGate()

    /// What the server advertises, as far as this client cares.
    /// `authorizedMediaOrigins` is optional and only decides which feature
    /// tokens a start request may negotiate.
    struct NeutralProtocolV3Capability: Equatable {
        let supported: Bool
        let authorizedMediaOrigins: Bool

        static let unsupported = NeutralProtocolV3Capability(
            supported: false,
            authorizedMediaOrigins: false
        )
    }

    private var availabilityByServerId: [String: NeutralProtocolV3Capability] = [:]
    private var probeByServerId: [String: Task<NeutralProtocolV3Capability, Error>] = [:]

    /// The active server's capability, or a terminal failure asking the user
    /// to update a server without Protocol V3.
    @discardableResult
    func requireNeutralProtocolV3() async throws -> NeutralProtocolV3Capability {
        let serverId = await TokenStore.shared.getActiveServerId()
        let available = try await capability(forServer: serverId)
        guard available.supported else {
            throw PlaybackV3TerminalFailure(
                reason: "server_upgrade_required",
                message: "Your Silo server hasn't been updated to support the latest version of this app. Please update your server, or use an earlier compatible version of Vivid until the server has been updated.",
                retryable: false
            )
        }
        return available
    }

    private func capability(forServer serverId: String) async throws -> NeutralProtocolV3Capability {
        if let cached = availabilityByServerId[serverId] {
            return cached
        }
        let probe = probeByServerId[serverId] ?? startProbe(forServer: serverId)
        do {
            let available = try await probe.value
            // Support doesn't go away while the app runs, so only a positive
            // answer is kept. A negative one may just mean a rolling server
            // upgrade or proxy fix hasn't reached this device yet, so the next
            // Play probes again rather than needing a relaunch.
            if available.supported {
                availabilityByServerId[serverId] = available
            }
            probeByServerId[serverId] = nil
            return available
        } catch {
            probeByServerId[serverId] = nil
            throw error
        }
    }

    private func startProbe(forServer serverId: String) -> Task<NeutralProtocolV3Capability, Error> {
        let probe = Task<NeutralProtocolV3Capability, Error> {
            do {
                let capability = try await VividAPI.shared.playbackV3Capability()
                return NeutralProtocolV3Capability(
                    supported: PlaybackSessionBridge.supportsNeutralProtocolV3(capability),
                    authorizedMediaOrigins: Self.asksForAuthorizedMediaOrigins(capability)
                )
            } catch where PlaybackSessionBridge.isMissingProtocolV3Capability(error) {
                // A server without the capability route answers 404 or 405.
                return .unsupported
            }
        }
        probeByServerId[serverId] = probe
        return probe
    }

    /// Whether a start may ask for proxy media origins. Native API 2 keeps
    /// media and the account bearer on the API origin, so `StreamRequest`
    /// refuses any absolute URL there. Asking anyway made a Silo server with a
    /// proxy node answer every route with a proxy URL that was then refused,
    /// so nothing played. Without the feature the server keeps every delivery
    /// on its own origin.
    static func asksForAuthorizedMediaOrigins(_ capability: PlaybackV3CapabilityResponse) -> Bool {
        capability.nativeApiMajor != 2
            && capability.features.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature)
    }
}
