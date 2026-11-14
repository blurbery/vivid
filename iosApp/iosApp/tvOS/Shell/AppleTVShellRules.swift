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

/// The saved tab that places Library in the tab bar: the first of Movies,
/// Series and For You, which Library replaces. The saved menu keeps all
/// three for clients that still show them.
func tvTabBarLibraryAnchor(in items: [PrimaryMenuItem]) -> PrimaryMenuItem? {
    items.first { item in
        if case .builtin(let builtin) = item { return builtin != .home }
        return false
    }
}

/// Whether Library sits before Home in the tab bar.
func tvTabBarLibraryLeadsHome(in items: [PrimaryMenuItem]) -> Bool {
    guard let anchor = tvTabBarLibraryAnchor(in: items),
          let library = items.firstIndex(of: anchor),
          let home = items.firstIndex(where: \.isHome) else { return false }
    return library < home
}

/// The saved menu with Home after or before every other saved tab. Movies,
/// Series and For You, which Library stands for, keep their own order.
func tabBarMenu(_ saved: [PrimaryMenuItem], libraryLeads: Bool) -> [PrimaryMenuItem] {
    let home = saved.filter(\.isHome)
    let others = saved.filter { !$0.isHome }
    return libraryLeads ? others + home : home + others
}
