import Foundation

// Plain rules the Apple TV shell and its settings apply. They build on every
// platform so the iOS test target can check them.

/// Where focus goes after the Apple TV tab list changes.
enum TVVisibleRootsFocusRearm: Equatable {
    case none
    case topMenu
    case content
}

/// Off the root page nothing moves. On it, a bar that held focus takes it
/// back; otherwise content takes it only when its page was removed.
func tvVisibleRootsFocusRearm(
    menuOwnedFocus: Bool,
    isShowingRoot: Bool,
    selectedRootWasRemoved: Bool
) -> TVVisibleRootsFocusRearm {
    guard isShowingRoot else { return .none }
    if menuOwnedFocus { return .topMenu }
    return selectedRootWasRemoved ? .content : .none
}

/// A tab bar edit is allowed when editing is, unless it changes the family
/// menu while this device overrides it.
func tvCustomizationMutationIsEnabled(
    allowsEditing: Bool,
    usesDeviceMenuOverride: Bool,
    changesFamilyMenu: Bool
) -> Bool {
    guard allowsEditing else { return false }
    return !(changesFamilyMenu && usesDeviceMenuOverride)
}
