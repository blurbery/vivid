import SwiftUI

/// The shared right-hand action cluster used at the top of tab-root screens:
/// Search, the iOS TV remote control, and a profile-avatar menu with
/// Settings / Switch Profile / Sign Out. Every root page renders the same
/// three controls so the header reads identically across Home, Libraries,
/// For You, and Calendar.
///
/// Each tab renders its own leading content (e.g. library selector on the
/// Libraries tab, the wordmark on Home) and places this view on the
/// trailing side of a single `HStack` row.
struct TabTopBarActions: View {
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var utilitiesSwapped = false
    /// Circular native Liquid Glass matching the close/remote detail
    /// controls. On by default because every root header now floats over
    /// the shared `PageChromeGlass` strip.
    var usesGlass = true
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    /// Opens the media-requests hub. The menu row only renders when the
    /// server reports `requests_enabled`, so the closure is inert otherwise.
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    /// Shared session cache so switching pages never refetches or flashes
    /// the avatar fallback.
    private let profileStore = CurrentProfileStore.shared
    var body: some View {
        #if os(iOS)
        EmptyView()
        #else
        // Icons spaced evenly, matching the clean top-right cluster used by
        // Plex. Order is fixed: Search, Remote (iOS), Profile.
        HStack(spacing: VividTheme.topBarIconSpacing) {
            if utilitiesSwapped { profileButton } else { searchButton }
            if utilitiesSwapped { searchButton } else { profileButton }
        }
        // No-op once cached; covers a page shown before the session-level
        // load finished.
        .task { await profileStore.refresh() }
        #endif
    }
    private var searchButton: some View {
        TopBarIconButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: "Search",
                usesGlass: usesGlass,
                action: onSearch
            )
    }
    private var profileButton: some View {
        ProfileAvatarMenu(
                profile: profileStore.profile,
                usesGlass: usesGlass,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
    }

}

/// Plain icon button used for utility actions (Search) in the top bar.
/// The 44×44 frame keeps a comfortable tap target while the glyph itself
/// stays small and chrome-free, matching Plex's top-right icons.
private struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let usesGlass: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.vividOnSurface)
                .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
                .modifier(TopBarCircularGlass(enabled: usesGlass))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Profile avatar rendered via `ProfileAvatarView` (which handles DiceBear
/// presets, URLs, emojis, and initials uniformly). Wraps a Menu exposing
/// Settings / Switch Profile / Sign Out so the user can reach app settings
/// and manage their account without leaving the current tab.
private struct ProfileAvatarMenu: View {
    let profile: UserProfile?
    let usesGlass: Bool
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            ProfileAvatarView(
                avatar: profile?.avatarEmoji,
                imageUrl: profile?.avatarImageUrl,
                name: profile?.name ?? "",
                size: usesGlass ? 30 : 36
            )
            .frame(
                width: usesGlass ? VividTheme.topBarIconHitSize : 36,
                height: usesGlass ? VividTheme.topBarIconHitSize : 36
            )
            .modifier(TopBarCircularGlass(enabled: usesGlass))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

/// Keeps all top-bar utilities on the exact same 44pt native-glass circle.
/// A modifier avoids duplicating branches inside Button and Menu labels.
private struct TopBarCircularGlass: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.vividGlass(in: Circle(), interactive: true)
        } else {
            content
        }
    }
}
