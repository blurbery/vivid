import Foundation

/// Keys for settings kept per server and profile on this device. Signed
/// out, the bare key is used; nothing is copied between the two.
///
/// This file stays Foundation-only and needs only the active server id and
/// profile id: `scripts/ci/check-tmdb-client.sh` compiles it whole on macOS.
@MainActor
enum MobileProfilePreferenceKeys {
    static func key(_ base: String) -> String {
        guard let scope else { return base }
        return "\(base).profile.\(scope)"
    }

    private static var scope: String? {
        guard let serverId = ServerRegistry.shared.activeServerId,
              let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        return Data("\(serverId)|\(profileId)".utf8).base64EncodedString()
    }
}
