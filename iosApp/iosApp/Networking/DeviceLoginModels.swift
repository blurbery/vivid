import Foundation

/// Body that starts a device sign-in (the Apple TV QR code flow).
struct DeviceLoginStartRequest: Codable {
    let deviceName: String?
    let devicePlatform: String?
}

/// `deviceCode` is the secret the TV polls with and is never shown.
/// `verificationUriComplete` is the URL in the QR code, which opens the web
/// app's `/activate?token=` page.
struct DeviceLoginStartResponse: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let matchCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresAt: Date
    let expiresIn: Int
    let interval: Int
    let deviceName: String
    let devicePlatform: String
}

/// Approves a waiting device sign-in for the signed-in account.
struct DeviceLoginDecisionRequest: Codable {
    let code: String
}

struct DeviceLoginPollRequest: Codable {
    let deviceCode: String
}

/// The tokens only arrive on the first `approved` reply: the server marks the
/// sign-in used straight away, so the TV has to keep them from that reply.
struct DeviceLoginPollResponse: Codable {
    let status: String
    let pollAfter: Int?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let user: AuthUser?
    var profileId: String? = nil
    var profileToken: String? = nil
}

enum DeviceLoginStatus: String {
    case pending
    case approved
    case denied
    case expired
    case consumed
    case unknown

    /// Any status this app doesn't know reads as `.unknown`.
    init(raw: String) {
        self = DeviceLoginStatus(rawValue: raw) ?? .unknown
    }
}
