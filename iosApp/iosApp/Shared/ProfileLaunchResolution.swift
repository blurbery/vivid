import Foundation

/// What launch does about the profile: show the picker, or carry on with the
/// remembered one.
enum ProfileLaunchResolution: Equatable, Sendable {
    case needsSelection
    case restore(RememberedProfile)
}
