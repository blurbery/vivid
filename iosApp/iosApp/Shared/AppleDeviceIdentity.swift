import Foundation
import UIKit

/// How this device introduces itself to servers.
struct AppleDeviceIdentity: Sendable {
    let id: String
    let name: String
    let platform: String
    let clientFamily: String
    let clientName: String
    let appVersion: String
    let appBuild: String
    let channel: String

    /// Made once per process, the first time anything asks.
    static let current: AppleDeviceIdentity = {
        #if os(tvOS)
        let platform = "tvOS"
        let family = "tv"
        let clientName = "Vivid Apple TV"
        #else
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let platform = "iOS"
        let family = isPad ? "tablet" : "mobile"
        let clientName = isPad ? "Vivid iPad" : "Vivid iPhone"
        #endif
        return AppleDeviceIdentity(
            id: storedDeviceIdentifier(),
            name: UIDevice.current.name,
            platform: platform,
            clientFamily: family,
            clientName: clientName,
            appVersion: bundleAppVersion,
            appBuild: bundleAppBuild,
            channel: buildChannel
        )
    }()

    static var bundleAppVersion: String { infoString("CFBundleShortVersionString") ?? "unknown" }
    static var bundleAppBuild: String { infoString("CFBundleVersion") ?? "unknown" }

    static var buildChannel: String {
        #if DEBUG
        return "dev"
        #else
        return infoString("VividBuildChannel") ?? "release"
        #endif
    }

    func applyHeaders(to request: inout URLRequest) {
        let headers = [
            ("X-Silo-Device-Id", id),
            ("X-Silo-Device-Name", name),
            ("X-Silo-Device-Platform", platform),
            ("X-Silo-Client-Family", clientFamily),
            ("X-Silo-Client", clientName),
            ("X-Silo-Client-Version", appVersion),
            ("X-Silo-Client-Build", appBuild),
            ("X-Silo-Client-Channel", channel),
        ]
        for (field, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    // MARK: - Device identifier

    private static let deviceIdentifierAccount = "com.blurbery.vivid.device.identity"

    private static func storedDeviceIdentifier() -> String {
        let keychain = SharedKeychain(audience: .userIndependent)
        let stored = Result { try keychain.getChecked(deviceIdentifierAccount) }
        let decision = deviceIdentifier(from: stored) { UUID().uuidString.lowercased() }
        if decision.save {
            keychain.set(decision.identifier, for: deviceIdentifierAccount)
        }
        return decision.identifier
    }

    /// Keeps a stored identifier, and otherwise makes a new one. A new one is
    /// saved unless the Keychain was only briefly unavailable, so the stored
    /// identifier is still there for the next launch.
    static func deviceIdentifier(
        from stored: Result<String?, Error>,
        makeIdentifier: () -> String
    ) -> (identifier: String, save: Bool) {
        switch stored {
        case .success(let value?) where !value.isEmpty:
            return (value, false)
        case .failure(let failure as KeychainReadFailure) where failure.isTemporary:
            return (makeIdentifier(), false)
        default:
            return (makeIdentifier(), true)
        }
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
