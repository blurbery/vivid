import Foundation

/// The profile last chosen on a server, tied to the account it was chosen
/// under. Stored as JSON, so the property names are the keys.
struct RememberedProfile: Codable, Equatable, Sendable {
    let profileID: String
    let requiredPINAtSelection: Bool
    let accountEpoch: String
}
