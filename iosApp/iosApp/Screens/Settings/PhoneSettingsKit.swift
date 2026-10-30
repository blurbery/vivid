#if os(iOS)
import SwiftUI
import UIKit

/// The icon, title and subtitle at the top of a settings page.
struct SettingsPageHeader: View {
    private let title: Text
    private let subtitle: Text
    private let systemImage: String
    private let imageName: String?

    // `tint` is accepted for callers but the icon is always drawn in white.
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String,
         tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage, tint: tint, imageName: imageName)
    }

    @_disfavoredOverload
    init<T: StringProtocol, S: StringProtocol>(title: T, subtitle: S, systemImage: String,
                                               tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage, tint: tint, imageName: imageName)
    }

    init(title: Text, subtitle: Text, systemImage: String,
         tint: Color = .white.opacity(0.85), imageName: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.imageName = imageName
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
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

    private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return Group {
            if let imageName {
                Image(imageName).resizable().scaledToFit().frame(width: 24, height: 24)
            } else {
                Image(systemName: systemImage).font(.title3)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: 48, height: 48)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// A settings section heading in small rounded capitals.
struct PhoneSettingsSectionHeader: View {
    private let title: Text

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S) {
        self.title = Text(title)
    }

    var body: some View {
        title
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(white: 0.62))
            .textCase(.uppercase)
    }
}

extension View {
    /// Places a page header as the first row of a settings list.
    func settingsPageHeaderRow() -> some View {
        listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// The settings list look, with the settings navigation chrome.
    func settingsListChrome() -> some View {
        vividGroupedListStyle()
            .vividScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
            .tint(.white)
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .environment(\.defaultMinListRowHeight, 60)
            .settingsNavigationChrome()
            .contentMargins(.top, 0, for: .scrollContent)
    }

    /// The settings navigation bar, the iPad reading column and the Duo
    /// back button.
    func settingsNavigationChrome() -> some View {
        vividNavigationTitleDisplayMode(.inline)
            .vividNavigationBarBackgroundHidden()
            .vividToolbarColorSchemeDark()
            .modifier(MobileTopScrollEdgeModifier())
            .toolbar(.visible, for: .navigationBar)
            .modifier(SettingsReadingColumn())
            .duoStripBackButton()
    }
}

/// On iPad, keeps settings content in a 760-point column centred in a wider
/// window, with the backdrop still filling the window.
private struct SettingsReadingColumn: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .safeAreaPadding(.horizontal, max(0, (width - 760) / 2))
                .background(VividAppBackdrop())
        } else {
            content
        }
    }
}
#endif
