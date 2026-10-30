import Foundation

/// A profile on the active server. Stored inside saved Apple TV accounts and
/// synced through iCloud, so the property names are the stored keys.
struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatarEmoji: String?
    let avatarImageUrl: String?
    let hasPin: Bool
    let isChild: Bool
    let isPrimary: Bool
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    let preferredMetadataLanguage: String?

    init(
        id: String,
        name: String,
        avatarEmoji: String?,
        avatarImageUrl: String? = nil,
        hasPin: Bool,
        isChild: Bool,
        isPrimary: Bool = false,
        subtitleLanguage: String? = nil,
        subtitleMode: String? = nil,
        showForcedSubtitles: Bool? = nil,
        preferredMetadataLanguage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.avatarImageUrl = avatarImageUrl
        self.hasPin = hasPin
        self.isChild = isChild
        self.isPrimary = isPrimary
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
        self.showForcedSubtitles = showForcedSubtitles
        self.preferredMetadataLanguage = preferredMetadataLanguage
    }
}

/// The body of a new-profile request.
struct CreateProfileBody: Codable {
    let name: String
    let avatarEmoji: String?
    let pin: String?
    let isChild: Bool
}

/// Why switching to a profile couldn't finish.
enum ProfileTransitionError: LocalizedError {
    case noActiveAccount
    case missingPINProof
    case noActiveServer
    case identityChanged
    case accountEpochUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            String(localized: "Sign in before selecting a profile.")
        case .missingPINProof:
            String(localized: "Vivid couldn't verify that profile's PIN. Please try again.")
        case .noActiveServer:
            String(localized: "Choose a server before selecting a profile.")
        case .identityChanged:
            String(localized: "The active account changed while selecting the profile. Please try again.")
        case .accountEpochUnavailable:
            String(localized: "Vivid couldn't securely remember this profile. Please try again.")
        }
    }
}
