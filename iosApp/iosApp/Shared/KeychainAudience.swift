import Foundation

/// Which tvOS Keychain an item belongs to. On iOS both audiences use the same
/// Keychain.
enum KeychainAudience: Equatable, Sendable {
    /// The signed-in Apple TV user's own Keychain.
    case currentUser
    /// The device-wide Keychain shared by every Apple TV user.
    case userIndependent
}
