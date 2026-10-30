#if os(tvOS)
import SwiftUI

/// The Apple TV settings pages, in rail order.
enum TVSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case playback
    case subtitles
    case server
    case plugins
    case seerr
    case metadata
    case diagnostics
    case about

    var id: String { rawValue }
}

extension TVSettingsCategory {
    fileprivate var title: String {
        switch self {
        case .general: String(localized: "General")
        case .playback: String(localized: "Playback")
        case .subtitles: String(localized: "Subtitles")
        case .server: String(localized: "Servers")
        case .plugins: String(localized: "Plugins")
        case .seerr: "Seerr"
        case .metadata: String(localized: "Metadata")
        case .diagnostics: String(localized: "Diagnostics")
        case .about: String(localized: "About")
        }
    }

    fileprivate var railDescription: String {
        switch self {
        case .general: String(localized: "App and navigation")
        case .playback: String(localized: "Quality, audio and episodes")
        case .subtitles: String(localized: "Language and appearance")
        case .server: String(localized: "Connection and version")
        case .plugins: String(localized: "Trailers and watched history")
        case .seerr: String(localized: "Media requests")
        case .metadata: String(localized: "Home cache and storage")
        case .diagnostics: String(localized: "Crash and hang reports")
        case .about: String(localized: "App details and contact")
        }
    }

    fileprivate var pageDescription: String {
        switch self {
        case .general: String(localized: "App-level options for this Apple TV.")
        case .playback: String(localized: "Streaming quality, audio and episode behavior for this Apple TV.")
        case .subtitles: String(localized: "Language, behavior, and on-screen appearance.")
        case .server: String(localized: "The media server this Apple TV is connected to.")
        case .plugins: String(localized: "Trailers and watched-history connections.")
        case .seerr: String(localized: "Connect Seerr to find and request movies and series.")
        case .metadata: String(localized: "Manage Home content saved on this Apple TV.")
        case .diagnostics: String(localized: "Crash and problem reports kept on this Apple TV.")
        case .about: String(localized: "Vivid for your Apple devices.")
        }
    }

    /// An asset for categories drawn with Vivid's own icon, else nil.
    fileprivate var assetIcon: String? {
        switch self {
        case .seerr: "SeerrSettingsIcon"
        case .about: "AboutInfoIcon"
        default: nil
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .server: "server.rack"
        case .plugins: "puzzlepiece.extension"
        case .metadata: "internaldrive"
        case .diagnostics: "stethoscope"
        case .seerr, .about: ""
        }
    }
}

/// Settings on Apple TV. Without a category it's the rail of settings
/// pages beside the profiles; with one, it's that page.
struct TVSettingsView: View {
    private let category: TVSettingsCategory?

    @State private var model = TVSettingsViewModel()
    @State private var selectedCategory: TVSettingsCategory = .general
    /// The row this page returns focus to.
    @State private var preferredFocus: Focus = .top
    @FocusState private var focus: Focus?
    @Namespace private var pageScope
    @Namespace private var railScope
    @Namespace private var paneScope
    @Environment(AppRouter.self) private var router
    @Environment(\.resetFocus) private var resetFocus

    init(category: TVSettingsCategory? = nil) {
        self.category = category
    }

    var body: some View {
        ZStack {
            SettingsBackdrop()
            if let category {
                categoryPage(category)
            } else {
                railPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .focusScope(pageScope)
        .onChange(of: focus) { _, newFocus in
            if let newFocus, !newFocus.isRail { preferredFocus = newFocus }
        }
        .task { await model.load() }
    }

    // MARK: Rail

    private var railPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(6)) {
                railOverview
                Spacer(minLength: TVSettingsLayout.scaled(12))
                VividCopyrightFooter()
                    .frame(maxWidth: .infinity)
                    .padding(.top, TVSettingsLayout.scaled(10))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, TVSettingsLayout.scaled(24))
            .padding(TVSettingsLayout.scaled(24))
        }
        .frame(maxWidth: TVSettingsLayout.pageWidth)
        .safeAreaPadding(.vertical, 44)
        .toolbar(.hidden, for: .navigationBar)
        .focusSection()
        .focusScope(railScope)
        .defaultFocus($focus, .rail(selectedCategory), priority: .userInitiated)
        .onAppear {
            focus = .rail(selectedCategory)
            Task { @MainActor in
                resetFocus(in: railScope)
                focus = .rail(selectedCategory)
            }
        }
        .onExitCommand { router.switchTab(to: .home) }
    }

    private var railOverview: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
            TVSettingsPageHeader(title: "Settings")
                .padding(.bottom, TVSettingsLayout.scaled(16))
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("PROFILES", topInset: 0)
                TVSavedAccountCards()
                    .padding(.horizontal, TVSettingsLayout.scaled(8))
                    .padding(.top, TVSettingsLayout.scaled(12))
                    .padding(.bottom, TVSettingsLayout.scaled(4))
            }
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("SETTINGS", topInset: 0)
                TVSettingsGroup {
                    ForEach(TVSettingsCategory.allCases) { categoryRow($0) }
                }
            }
        }
    }

    private func categoryRow(_ category: TVSettingsCategory) -> some View {
        Button { open(category) } label: {
            HStack(spacing: TVSettingsLayout.scaled(16)) {
                categoryIcon(category)
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(2)) {
                    Text(category.title)
                        .font(.tvSettings(25, weight: .medium))
                    Text(category.railDescription)
                        .font(.tvSettings(19))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.tvSettings(17, weight: .semibold))
                    .opacity(0.5)
            }
        }
        .buttonStyle(RailRowStyle())
        .focused($focus, equals: .rail(category))
    }

    private func categoryIcon(_ category: TVSettingsCategory) -> some View {
        Group {
            if let asset = category.assetIcon {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: TVSettingsLayout.scaled(28), height: TVSettingsLayout.scaled(28))
            } else {
                Image(systemName: category.symbol)
            }
        }
        .font(.tvSettings(22, weight: .medium))
        .frame(width: TVSettingsLayout.scaled(48), height: TVSettingsLayout.scaled(48))
        .background(TVSettingsPalette.iconFill,
                    in: RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12))
            .strokeBorder(TVSettingsPalette.separator, lineWidth: 1))
    }

    private func open(_ category: TVSettingsCategory) {
        selectedCategory = category
        preferredFocus = Self.initialFocus(for: category, followsDevice: model.followsDeviceCaptions)
        focus = nil
        router.path.append(category)
    }

    // MARK: Category page

    private func categoryPage(_ category: TVSettingsCategory) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsPageHeader(title: category.title, subtitle: category.pageDescription)
                pane(category)
                    .padding(.top, TVSettingsLayout.scaled(18))
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.bottom, TVSettingsLayout.scaled(64))
        }
        .contentMargins(.horizontal, TVSettingsLayout.scaled(24), for: .scrollContent)
        .scrollClipDisabled()
        .id(category)
        .transition(.opacity)
        .frame(maxWidth: TVSettingsLayout.pageWidth, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.top, 48)
        .safeAreaPadding(.bottom, 44)
        .toolbar(.hidden, for: .navigationBar)
        .focusSection()
        .focusScope(paneScope)
        .defaultFocus($focus, preferredFocus, priority: .userInitiated)
        .onAppear {
            if preferredFocus == .top {
                preferredFocus = Self.initialFocus(for: category, followsDevice: model.followsDeviceCaptions)
            }
            focus = preferredFocus
        }
        .onExitCommand {
            focus = nil
            router.goBack()
        }
    }

    @ViewBuilder
    private func pane(_ category: TVSettingsCategory) -> some View {
        switch category {
        case .general: GeneralPane(focus: $focus)
        case .playback: PlaybackPane(model: model, focus: $focus)
        case .subtitles: SubtitlesPane(model: model, focus: $focus)
        case .server: ServersPane(model: model, focus: $focus)
        case .plugins: PluginsSettingsView()
        case .seerr: TVSeerrSettingsPane()
        case .metadata: TVHomeMetadataSettingsPane()
        case .diagnostics: TVDiagnosticsSettingsPane()
        case .about: EmptyView()
        }
    }

    private static func initialFocus(for category: TVSettingsCategory, followsDevice: Bool) -> Focus {
        switch category {
        case .general: .generalLanguage
        case .subtitles where followsDevice: .useDeviceSettings
        default: .top
        }
    }
}

extension TVSettingsView {
    /// The rows a settings page remembers focus on.
    enum Focus: Hashable {
        case rail(TVSettingsCategory)
        /// The first row of a page.
        case top
        case generalLanguage, theme, spotlight, homeSections, collections, customiseTabBar
        case audioLanguage, boostLevel, showNextUp
        case backupLanguage, behavior, useDeviceSettings
        case fontSize, fontColor, backgroundStyle, backgroundOpacity, backgroundColor, position
        case manageServers

        var isRail: Bool {
            if case .rail = self { return true }
            return false
        }
    }
}

// MARK: - Servers

extension TVSettingsView {
    /// The connected server for this profile, which can be renamed for the
    /// profile, and the way to the full server list.
    struct ServersPane: View {
        let model: TVSettingsViewModel
        let focus: FocusState<Focus?>.Binding
        @State private var store = TVSavedAccountStore.shared
        @State private var renaming: TVSavedAccount?
        @Environment(AppRouter.self) private var router

        private var renamableAccount: TVSavedAccount? {
            model.serverDisplayName.isEmpty ? nil : store.activeAccount
        }

        var body: some View {
            let account = renamableAccount
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("ACTIVE SERVER")
                TVSettingsGroup {
                    if let account {
                        Button { renaming = account } label: {
                            HStack(spacing: TVSettingsLayout.scaled(16)) {
                                TVSettingsRowLabel(title: "Server")
                                Text(account.serverName ?? model.serverDisplayName)
                                    .font(.tvSettings(24))
                                    .opacity(0.68)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.tvSettings(18, weight: .semibold))
                                    .opacity(0.55)
                            }
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .accessibilityHint("Rename this server for this profile")
                        .focused(focus, equals: .top)
                    } else {
                        TVSettingsInfoRow(title: "Server",
                                          value: model.serverDisplayName.isEmpty ? String(localized: "Not configured") : model.serverDisplayName)
                    }
                    if !model.serverAddress.isEmpty && model.serverAddress != model.serverDisplayName {
                        TVSettingsInfoRow(title: "Address", value: model.serverAddress)
                    }
                    Button { router.navigate(to: .serverList) } label: {
                        HStack(spacing: TVSettingsLayout.scaled(16)) {
                            TVSettingsRowLabel(title: "Manage Servers")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.tvSettings(18, weight: .semibold))
                                .opacity(0.55)
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused(focus, equals: account == nil ? .top : .manageServers)
                }
                if account != nil {
                    TVSettingsFooter("Select Server to rename it for this profile.")
                }
            }
            .navigationDestination(item: $renaming) { RenameServerPage(account: $0) }
        }
    }

    /// Names the server for one profile.
    struct RenameServerPage: View {
        let account: TVSavedAccount
        @State private var name: String
        @State private var failed = false
        @State private var store = TVSavedAccountStore.shared
        @Environment(\.dismiss) private var dismiss

        init(account: TVSavedAccount) {
            self.account = account
            _name = State(initialValue: account.serverName ?? "")
        }

        private var address: String { ServerRegistry.shared.entry(with: account.serverID)?.url ?? "" }
        private var defaultName: String { account.defaultServerLabel }

        var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                    TVSettingsPageHeader(title: Text("Rename Server"), subtitle: Text(address))
                        .padding(.horizontal, TVSettingsLayout.scaled(24))
                        .padding(.bottom, TVSettingsLayout.scaled(18))
                    TVSettingsGroup {
                        TVSettingsFieldRow(title: "Name",
                                           detail: "Shown for this profile only, under its profile picture and on the Servers page. Leave it blank to show “\(defaultName)”.") {
                            TextField(defaultName, text: $name)
                                .textFieldStyle(.plain)
                        }
                        Button { rename(to: name) } label: { TVSettingsRowLabel(title: "Save") }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        if !(account.serverName ?? "").isEmpty {
                            Button { rename(to: nil) } label: {
                                TVSettingsRowLabel(title: "Use Server Name",
                                                   detail: "Show “\(defaultName)” for this profile again.")
                            }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        }
                    }
                    if failed {
                        TVSettingsFooter(String(localized: "Couldn’t rename the server. Try again."))
                    }
                }
                .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, TVSettingsLayout.scaled(24))
                .padding(.vertical, TVSettingsLayout.scaled(48))
                .frame(maxWidth: .infinity)
            }
            .tvSettingsPageSurface()
        }

        private func rename(to name: String?) {
            if store.renameServer(for: account.id, to: name) {
                dismiss()
            } else {
                failed = true
            }
        }
    }

}
#endif
