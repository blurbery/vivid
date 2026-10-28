#if !os(tvOS)
import SwiftUI

/// Consistent introduction for Settings detail pages, matching the web
/// client's icon, title, and concise explanatory copy.
struct SettingsPageHeader: View {
    private let title: Text
    private let subtitle: Text
    let systemImage: String
    var tint: Color = .white.opacity(0.85)
    var imageName: String? = nil

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String,
         tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage, tint: tint, imageName: imageName)
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<T: StringProtocol, S: StringProtocol>(title: T, subtitle: S, systemImage: String,
                                               tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage, tint: tint, imageName: imageName)
    }

    /// Mixes a localised and a verbatim string, e.g. `Text("Title")` and `Text(value)`.
    init(title: Text, subtitle: Text, systemImage: String,
         tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.imageName = imageName
    }

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
                title
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vividOnSurface)

                subtitle
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
    private let title: Text
    init(_ title: LocalizedStringKey) { self.title = Text(title) }
    @_disfavoredOverload init<S: StringProtocol>(_ title: S) { self.title = Text(title) }
    var body: some View {
        title
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(white: 0.62))
            .textCase(.uppercase)
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
            .modifier(MobileTopScrollEdgeModifier())
            .toolbar(.visible, for: .navigationBar)
            .modifier(TabletSettingsWidth())
            .duoStripBackButton()
            #endif
    }
}
#endif

#if os(iOS)
private struct TabletSettingsWidth: ViewModifier {
    /// Padding the safe area keeps the 760-point column while each page's own
    /// backdrop still fills the screen. Narrowing the frame drew that backdrop
    /// in the column only, a second tone beside the full-width one behind it.
    @State private var width: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .safeAreaPadding(.horizontal, max(0, (width - 760) / 2))
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .background(VividAppBackdrop())
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
    /// The iPhone Duo's landscape inner screen stands the bar up in its
    /// side strip, in the same order from top to bottom.
    var isVertical = false
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var swapped = false
    private var profile: UserProfile? { CurrentProfileStore.shared.profile ?? TVSavedAccountStore.shared.activeAccount?.profile }
    var body: some View {
        if isVertical {
            ViewThatFits(in: .vertical) {
                verticalNavigationItems(spacing: 4)
                verticalNavigationItems(spacing: 2)
            }
            .buttonStyle(.plain).padding(.vertical, 7).frame(width: 50)
            .vividGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
            .frame(maxHeight: 420)
        } else {
            ViewThatFits(in: .horizontal) {
                navigationItems(spacing: 4)
                navigationItems(spacing: 2)
            }
            .buttonStyle(.plain).padding(.horizontal, 7).frame(height: 50)
            .vividGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
            .frame(maxWidth: 420)
        }
    }

    private func verticalNavigationItems(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if swapped { profileButton } else { searchButton }
            Rectangle().fill(.white.opacity(0.2)).frame(width: 24, height: 1)
            VStack(spacing: spacing) {
                ForEach(items) { item in
                    Button { onSelect(item.id) } label: {
                        Image(systemName: selectedID == item.id ? (item.selectedIcon ?? item.icon) : item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(maxHeight: .infinity).frame(width: 34)
                            .foregroundStyle(selectedID == item.id ? Color.black : .white.opacity(0.7))
                            .background(selectedID == item.id ? Color.white : .clear, in: Capsule())
                            .contentShape(Rectangle())
                    }.frame(maxHeight: .infinity)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                }
            }.frame(maxHeight: .infinity).frame(width: 44)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 24, height: 1)
            if swapped { searchButton } else { profileButton }
        }
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
