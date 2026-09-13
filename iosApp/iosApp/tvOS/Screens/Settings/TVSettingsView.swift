#if os(tvOS)
import SwiftUI

struct TVSettingsView: View {
    @State private var viewModel = TVSettingsViewModel()
    @State private var selectedCategory: TVSettingsCategory = .general
    private let pageCategory: TVSettingsCategory?
    @State private var preferredDetailFocus: TVSettingsDetailFocus = .top
    @FocusState private var railFocus: RailItem?
    @FocusState private var detailFocus: TVSettingsDetailFocus?
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var settingsFocusScope
    @Namespace private var railFocusScope
    @Namespace private var detailFocusScope
    @Environment(AppRouter.self) private var router

    init(category: TVSettingsCategory? = nil) {
        pageCategory = category
        _selectedCategory = State(initialValue: category ?? .general)
    }

    var body: some View {
        ZStack {
            SettingsBackdrop()

            settingsContent

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(.white)
        .preferredColorScheme(.dark)
        .task {
            await viewModel.load()
        }
        .onChange(of: detailFocus) { _, focus in
            if let focus {
                preferredDetailFocus = focus
            }
        }

    }

    private func restoreMenuFocus() {
        guard pageCategory == nil else { return }
        detailFocus = nil
        railFocus = .category(selectedCategory)
        Task { @MainActor in
            await Task.yield()
            guard pageCategory == nil else { return }
            resetFocus(in: railFocusScope)
            railFocus = .category(selectedCategory)
        }
    }

    private var settingsContent: some View {
        Group {
            if pageCategory != nil {
                settingsCategoryPage
            } else {
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        rail.padding(24)
                    }
                        .frame(maxWidth: TVSettingsLayout.pageWidth)
                        .defaultFocus($railFocus, .category(selectedCategory), priority: .userInitiated)
                        .focusSection()
                        .focusScope(railFocusScope)
                        .onAppear(perform: restoreMenuFocus)
                        .onExitCommand(perform: exitSettingsToHome)
                        .safeAreaPadding(.vertical, 44)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .focusScope(settingsFocusScope)
    }

    private var settingsCategoryPage: some View {
        ZStack {
            detailPane
                .frame(maxWidth: TVSettingsLayout.pageWidth, maxHeight: .infinity, alignment: .topLeading)
                .defaultFocus($detailFocus, preferredDetailFocus, priority: .userInitiated)
                .focusSection()
                .focusScope(detailFocusScope)
                .safeAreaPadding(.top, 48)
                .safeAreaPadding(.bottom, 44)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            railFocus = nil
            if preferredDetailFocus == .top {
                preferredDetailFocus = initialDetailFocus(for: selectedCategory)
            }
            detailFocus = preferredDetailFocus
        }
        .onExitCommand(perform: returnFocusToRail)
    }

    // MARK: - Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVSettingsOverview {
                profileRow
            } categories: {
                ForEach(visibleCategories) { category in categoryRow(category) }
            }

            Spacer(minLength: 12)

            VividCopyrightFooter()
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 24)
    }

    private var profileRow: some View {
        TVSavedAccountCards()
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    @ViewBuilder private func categoryImage(_ category: TVSettingsCategory) -> some View {
        if category == .seerr || category == .about {
            Image(category == .about ? "AboutInfoIcon" : "SeerrSettingsIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: category.icon)
        }
    }

    private func categoryRow(_ category: TVSettingsCategory) -> some View {
        Button {
            enterDetailPane(for: category)
        } label: {
            HStack(spacing: 16) {
                categoryImage(category)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(
                        TVSettingsPalette.iconFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(TVSettingsPalette.separator, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: 25, weight: .medium))

                    Text(category.railDescription)
                        .font(.system(size: 19))
                        .opacity(0.7)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .opacity(0.5)
            }
        }
        .buttonStyle(TVSettingsRailRowStyle())
        .focused($railFocus, equals: .category(category))

    }

    private func enterDetailPane(for category: TVSettingsCategory) {
        guard pageCategory == nil else { return }
        selectedCategory = category
        preferredDetailFocus = initialDetailFocus(for: category)
        railFocus = nil
        router.path.append(category)
    }

    private func initialDetailFocus(for category: TVSettingsCategory) -> TVSettingsDetailFocus {
        if category == .general {
            return .generalHomeScreen
        }
        if category == .subtitles,
           viewModel.subtitleMatchesSystemAppearance {
            return .subtitleUseDeviceSettings
        }
        return .top
    }

    private func returnFocusToRail() {
        detailFocus = nil
        router.goBack()
    }

    /// The tab request is the only action needed: TVMainTabView's
    /// `requestedTab` handler routes `.home` through `selectRoot`, which pops
    /// to root itself (unconditionally, including when Home is already the
    /// selected root). Popping here too produced a second `popToRoot` and a
    /// duplicate navigation breadcrumb for one exit.
    private func exitSettingsToHome() {
        router.switchTab(to: .home)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if selectedCategory == .about {
            AboutSettingsView()
        } else {
            categoryControls
        }
    }

    private var categoryControls: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                paneHeader

                paneContent
                    .padding(.top, 18)
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.bottom, 64)
        }
        // Keep focused row scaling and shadows inside a deliberate gutter
        // instead of letting the scroll view trim their rounded edges.
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .scrollClipDisabled()
        // Rebuild the scroll view per category so it opens at the top.
        // Safe: selection only changes while focus is in the rail.
        .id(selectedCategory)
        .transition(.opacity)
    }

    private var paneHeader: some View {
        TVSettingsPageHeader(title: selectedCategory.title, subtitle: selectedCategory.blurb)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedCategory {
        case .general:
            TVGeneralSettingsPane(
                detailFocus: $detailFocus
            )
        case .playback:
            TVPlaybackSettingsPane(
                viewModel: viewModel,
                detailFocus: $detailFocus
            )
        case .subtitles:
            TVSubtitleSettingsPane(
                viewModel: viewModel,
                detailFocus: $detailFocus
            )
        case .plugins:
            PluginsSettingsView()
        case .server:
            serverPane
        case .seerr:
            TVSeerrSettingsPane()
        case .metadata:
            TVHomeMetadataSettingsPane()
        case .about:
            AboutSettingsView()
        }
    }

    // MARK: - Server pane

    private var serverPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("ACTIVE SERVER")

            TVSettingsGroup {
                TVSettingsInfoRow(
                    title: "Server",
                    value: viewModel.serverDisplayName.isEmpty
                        ? "Not configured"
                        : viewModel.serverDisplayName
                )

                if !viewModel.serverUrl.isEmpty,
                   viewModel.serverDisplayName != viewModel.serverUrl {
                    TVSettingsInfoRow(title: "Address", value: viewModel.serverUrl)
                }

                Button { router.navigate(to: .serverList) } label: {
                    HStack(spacing: 16) {
                        TVSettingsRowLabel(title: "Manage Servers")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($detailFocus, equals: .top)

            }

        }
    }

    // MARK: - Rail model

    enum RailItem: Hashable {
        case profile
        case category(TVSettingsCategory)
        case signOut
    }

    private var visibleCategories: [TVSettingsCategory] { TVSettingsCategory.allCases }

}

enum TVSettingsDetailFocus: Hashable {
    case top
    case generalHomeSections
    case generalHomeScreen
    case generalTopMenu
    case playbackAudioLanguage
    case playbackBufferAhead
    case playbackNextUpPrompt
    case subtitleBehavior
    case subtitleUseDeviceSettings
    case subtitleFontSize
    case subtitleFontColor
    case subtitleBackgroundStyle
    case subtitleBackgroundOpacity
    case subtitleBackgroundColor
    case subtitlePosition
}

// MARK: - Categories

enum TVSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case playback
    case subtitles
    case server
    case plugins
    case seerr
    case metadata
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles"
        case .plugins: return "Plugins"
        case .server: return "Servers"
        case .seerr: return "Seerr"
        case .metadata: return "Metadata"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .subtitles: return "captions.bubble"
        case .plugins: return "puzzlepiece.extension"
        case .server: return "server.rack"
        case .seerr: return "sparkles"
        case .metadata: return "internaldrive"
        case .about: return "info.circle"
        }
    }

    var blurb: String {
        switch self {
        case .general:
            return "App-level options for this Apple TV."
        case .playback:
            return "Streaming quality and episode behavior for this Apple TV."
        case .subtitles:
            return "Language, behavior, and on-screen appearance."
        case .plugins:
            return "Trailers and watched-history connections."
        case .server:
            return "The media server this Apple TV is connected to."
        case .seerr:
            return "Connect Seerr to find and request movies and series."
        case .metadata:
            return "Manage Home content saved on this Apple TV."
        case .about:
            return "Vivid for your Apple devices."
        }
    }

    var railDescription: String {
        switch self {
        case .general: return "App and navigation"
        case .playback: return "Quality and episodes"
        case .subtitles: return "Language and appearance"
        case .plugins: return "Trailers and watched history"
        case .server: return "Connection and version"
        case .seerr: return "Media requests"
        case .metadata: return "Home cache and storage"
        case .about: return "App details and contact"
        }
    }

}
#endif
