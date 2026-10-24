import Foundation

enum ProfileTransitionError: LocalizedError {
    case noActiveAccount
    case missingPINProof
    case noActiveServer
    case identityChanged
    case accountEpochUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return String(localized: "Sign in before selecting a profile.")
        case .missingPINProof:
            return String(localized: "Vivid couldn't verify that profile's PIN. Please try again.")
        case .noActiveServer:
            return String(localized: "Choose a server before selecting a profile.")
        case .identityChanged:
            return String(localized: "The active account changed while selecting the profile. Please try again.")
        case .accountEpochUnavailable:
            return String(localized: "Vivid couldn't securely remember this profile. Please try again.")
        }
    }
}
