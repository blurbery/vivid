#if os(iOS)
import SwiftUI

/// The iPhone and iPad tab bar: the tabs on a glass capsule between the
/// Search and Profile buttons. Laid out across the bottom, or down the side
/// on the iPad landscape side bar and the Duo's side strip.
struct MobileGlassNavigationBar: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        var icon: String = "house"
        var selectedIcon: String? = nil
    }

    let items: [Item]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onSearch: () -> Void
    let onProfile: () -> Void
    let isVertical: Bool

    @AppStorage private var swapsUtilities: Bool
    @State private var currentProfile = CurrentProfileStore.shared
    @State private var accounts = TVSavedAccountStore.shared

    init(items: [Item], selectedID: String?, onSelect: @escaping (String) -> Void,
         onSearch: @escaping () -> Void = {}, onProfile: @escaping () -> Void = {}, isVertical: Bool = false) {
        self.items = items
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onSearch = onSearch
        self.onProfile = onProfile
        self.isVertical = isVertical
        _swapsUtilities = AppStorage(wrappedValue: false, MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities"))
    }

    var body: some View {
        if isVertical {
            ViewThatFits(in: .vertical) {
                verticalArrangement(spacing: 4)
                verticalArrangement(spacing: 2)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)
            .frame(width: 50)
            .vividGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
            .frame(maxHeight: 420)
        } else {
            ViewThatFits(in: .horizontal) {
                horizontalArrangement(spacing: 4)
                horizontalArrangement(spacing: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .frame(height: 50)
            .vividGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
            .frame(maxWidth: 420)
        }
    }

    private func horizontalArrangement(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            leadingUtility
            divider(width: 1, height: 24)
            HStack(spacing: spacing) {
                ForEach(items) { item in
                    itemButton(item, vertical: false)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            divider(width: 1, height: 24)
            trailingUtility
        }
    }

    private func verticalArrangement(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            leadingUtility
            divider(width: 24, height: 1)
            VStack(spacing: spacing) {
                ForEach(items) { item in
                    itemButton(item, vertical: true)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .frame(width: 44)
            divider(width: 24, height: 1)
            trailingUtility
        }
    }

    private func divider(width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: width, height: height)
    }

    private func itemButton(_ item: Item, vertical: Bool) -> some View {
        let isSelected = item.id == selectedID
        let icon = isSelected ? (item.selectedIcon ?? item.icon) : item.icon
        return Button { onSelect(item.id) } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
                .frame(width: vertical ? 34 : nil, height: vertical ? nil : 34)
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.7))
                .background(isSelected ? Color.white : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var leadingUtility: some View {
        if swapsUtilities { profileButton } else { searchButton }
    }

    @ViewBuilder
    private var trailingUtility: some View {
        if swapsUtilities { searchButton } else { profileButton }
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Search")
    }

    private var profileButton: some View {
        let profile = currentProfile.profile ?? accounts.activeAccount?.profile
        return Button(action: onProfile) {
            ProfileAvatarView(avatar: profile?.avatarEmoji, imageUrl: profile?.avatarImageUrl,
                              name: profile?.name ?? "", size: 32)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Profile settings")
    }
}
#endif
