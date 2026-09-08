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
            return "Sign in before selecting a profile."
        case .missingPINProof:
            return "Vivid couldn't verify that profile's PIN. Please try again."
        case .noActiveServer:
            return "Choose a server before selecting a profile."
        case .identityChanged:
            return "The active account changed while selecting the profile. Please try again."
        case .accountEpochUnavailable:
            return "Vivid couldn't securely remember this profile. Please try again."
        }
    }
}
