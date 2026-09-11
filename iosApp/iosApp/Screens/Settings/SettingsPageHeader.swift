#if !os(tvOS)
import SwiftUI

/// Consistent introduction for Settings detail pages, matching the web
/// client's icon, title, and concise explanatory copy.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .white.opacity(0.85)
    var imageName: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let imageName {
                    Image(imageName).resizable().scaledToFit().frame(width: 24, height: 24)
                } else {
                    Image(systemName: systemImage).font(.title3)
                }
            }
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 48, height: 48)
                .background(Color(red: 0.12, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vividOnSurface)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.vividSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneSettingsSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(white: 0.62))
    }
}

extension View {
    func settingsPageHeaderRow() -> some View {
        listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func settingsListChrome() -> some View {
        vividGroupedListStyle()
            .vividScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
            .tint(.white)
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .environment(\.defaultMinListRowHeight, 60)
            .settingsNavigationChrome()
            #if os(iOS)
            .contentMargins(.top, 0, for: .scrollContent)
            #endif
    }

    func settingsNavigationChrome() -> some View {
        vividNavigationTitleDisplayMode(.inline)
            .vividNavigationBarBackgroundHidden()
            .vividToolbarColorSchemeDark()
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            .modifier(TabletSettingsWidth())
            #endif
    }
}
#endif

#if os(iOS)
private struct TabletSettingsWidth: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .background(Color.black.ignoresSafeArea())
        } else {
            content
        }
    }
}

struct MobileGlassNavigationBar: View {
    struct Item: Identifiable { let id: String; let title: String; var icon: String = "house"; var selectedIcon: String? = nil }
    let items: [Item]
    let selectedID: String?
    let onSelect: (String) -> Void
    var onSearch: () -> Void = {}
    var onProfile: () -> Void = {}
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var swapped = false
    private var profile: UserProfile? { CurrentProfileStore.shared.profile ?? TVSavedAccountStore.shared.activeAccount?.profile }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            navigationItems(spacing: 4)
            navigationItems(spacing: 2)
        }
        .buttonStyle(.plain).padding(.horizontal, 7).frame(height: 50)
        .vividGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
        .frame(maxWidth: 420)
    }

    private func navigationItems(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if swapped { profileButton } else { searchButton }
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 24)
            HStack(spacing: spacing) {
                ForEach(items) { item in
                    Button { onSelect(item.id) } label: {
                        Image(systemName: selectedID == item.id ? (item.selectedIcon ?? item.icon) : item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .foregroundStyle(selectedID == item.id ? Color.black : .white.opacity(0.7))
                            .background(selectedID == item.id ? Color.white : .clear, in: Capsule())
                            .contentShape(Rectangle())
                    }.frame(maxWidth: .infinity)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                }
            }.frame(maxWidth: .infinity).frame(height: 44)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 24)
            if swapped { searchButton } else { profileButton }
        }
    }
    private var searchButton: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Search")
    }
    private var profileButton: some View {
        Button(action: onProfile) {
            ProfileAvatarView(avatar: profile?.avatarEmoji, imageUrl: profile?.avatarImageUrl, name: profile?.name ?? "", size: 32)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Profile settings")
    }
}
#endif
