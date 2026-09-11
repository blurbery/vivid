#if os(tvOS)
import SwiftUI

struct TVSettingsView: View {
    @State private var viewModel = TVSettingsViewModel()
    @State private var selectedCategory: TVSettingsCategory = .general
    private let pageCategory: TVSettingsCategory?
    @State private var activePicker: TVSettingsPickerRequest?
    @State private var pendingPickerFocus: TVSettingsDetailFocus?
    @State private var isRestoringDetailFocus = false
    @State private var preferredFocusOwner: FocusOwner = .rail
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

            if let activePicker {
                TVSettingsPickerSheet(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    onDismiss: dismissPicker
                )
                .onDisappear(perform: restorePickerFocus)
                .zIndex(2)
            }


        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await viewModel.load()
        }
        .onChange(of: railFocus) { _, focus in
            if focus != nil,
               activePicker == nil,
               !isRestoringDetailFocus {
                preferredFocusOwner = .rail
            }
        }
        .onChange(of: detailFocus) { _, focus in
            if let focus,
               activePicker == nil,
               !isRestoringDetailFocus {
                preferredDetailFocus = focus
                preferredFocusOwner = .detail
            }
        }

    }

    private func restoreMenuFocus() {
        guard pageCategory == nil, activePicker == nil else { return }
        preferredFocusOwner = .rail
        detailFocus = nil
        railFocus = .category(selectedCategory)
        Task { @MainActor in
            await Task.yield()
            guard pageCategory == nil else { return }
            resetFocus(in: railFocusScope)
            railFocus = .category(selectedCategory)
        }
    }

    private var hasSettingsOverlay: Bool {
        activePicker != nil
    }

    private var settingsContent: some View {
        Group {
            if pageCategory != nil {
                settingsCategoryPage
            } else {
                ZStack {
                    SettingsBackdrop()
                    ScrollView(.vertical, showsIndicators: false) {
                        rail.padding(24)
                    }
                        .frame(maxWidth: TVSettingsLayout.pageWidth)
                        .disabled(hasSettingsOverlay || isRestoringDetailFocus)
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
            SettingsBackdrop()
            detailPane
                .frame(maxWidth: TVSettingsLayout.pageWidth, maxHeight: .infinity, alignment: .topLeading)
                .disabled(hasSettingsOverlay)
                .defaultFocus($detailFocus, preferredDetailFocus, priority: .userInitiated)
                .focusSection()
                .focusScope(detailFocusScope)
                .safeAreaPadding(.top, 48)
                .safeAreaPadding(.bottom, 44)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            preferredFocusOwner = .detail
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
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.vividOnSurface)

                Text("Make Vivid work the way you like.")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            profileRow
                .padding(.bottom, 10)

            TVSettingsGroup {
                ForEach(visibleCategories) { category in categoryRow(category) }
            }

            Spacer(minLength: 12)

            VividCopyrightFooter()
            .padding(.leading, 20)
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 24)
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles").font(.system(size: 24, weight: .semibold)).padding(.leading, 20)
            TVSavedAccountCards()
        }
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
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 48, height: 48)
                    .background(
                        Color(red: 0.12, green: 0.13, blue: 0.15),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

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
        preferredFocusOwner = .detail
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
        guard activePicker == nil,
              !isRestoringDetailFocus else {
            return
        }
        preferredFocusOwner = .rail
        detailFocus = nil
        router.goBack()
    }

    private func presentPicker(_ request: TVSettingsPickerRequest) {
        // Remove every underlying focus candidate in the same update that
        // mounts the modal. The picker then becomes the sole focus owner.
        preferredFocusOwner = .detail
        preferredDetailFocus = request.returnFocus
        railFocus = nil
        detailFocus = nil
        activePicker = request
    }

    private func dismissPicker() {
        guard let target = activePicker?.returnFocus else {
            activePicker = nil
            return
        }

        // Keep the rail out of the graph while SwiftUI removes the modal.
        // The exact row is restored from the overlay's onDisappear callback,
        // after its focus subtree has actually left the hierarchy.
        preferredFocusOwner = .detail
        preferredDetailFocus = target
        pendingPickerFocus = target
        isRestoringDetailFocus = true
        activePicker = nil
    }

    private func restorePickerFocus() {
        guard let target = pendingPickerFocus else { return }
        Task { @MainActor in
            await Task.yield()
            guard pendingPickerFocus == target, activePicker == nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                detailFocus = target
                pendingPickerFocus = nil
                isRestoringDetailFocus = false
            }
        }
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

    private var detailPane: some View {
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
        HStack(alignment: .center, spacing: 20) {
            categoryImage(selectedCategory)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 62, height: 62)
                .background(
                    Color(red: 0.12, green: 0.13, blue: 0.15),
                    in: RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(selectedCategory.title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(selectedCategory.blurb)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
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
                detailFocus: $detailFocus,
                presentPicker: presentPicker
            )
        case .subtitles:
            TVSubtitleSettingsPane(
                viewModel: viewModel,
                detailFocus: $detailFocus,
                presentPicker: presentPicker
            )
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

    private enum FocusOwner {
        case rail
        case detail
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
    case seerr
    case metadata
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles"
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
        case .server: return "Connection and version"
        case .seerr: return "Media requests"
        case .metadata: return "Home cache and storage"
        case .about: return "App details and contact"
        }
    }


}
#endif
