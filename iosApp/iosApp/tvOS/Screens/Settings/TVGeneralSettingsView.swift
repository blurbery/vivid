#if os(tvOS)
import SwiftUI

/// Family-synced tvOS interface preferences. Every control is a native focus
/// target; the menu editor changes data only on Select and never intercepts
/// directional movement, preserving the stable focus graph described in
/// `docs/apple-tv-focus.md`.
struct TVGeneralSettingsPane: View {
    @AppStorage(VividAppTheme.storageKey, store: .standard) private var theme: VividAppTheme = .graphite
    @State private var homeSections = HomeSectionPreferences.shared
    @State private var preferences = UICustomizationPreferences.shared
    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var showsHomeSectionsEditor = false
    @State private var showsHomeScreenSettings = false
    @State private var showsMenuEditor = false
    @State private var showsStudiosNetworksEditor = false
    @State private var studiosNetworks = StudiosNetworksStore.shared
    @State private var tmdb = TVTMDbStore.shared
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    @Environment(\.scenePhase) private var scenePhase
    @State private var language = VividAppLanguage.saved
    @State private var reopenLanguage: VividAppLanguage?

    private func reopenMessage(for language: VividAppLanguage) -> Text {
        if let name = language.nativeName {
            Text("Vivid will use \(name) the next time it opens. Press the TV button twice, swipe up on Vivid, then open it again.")
        } else {
            Text("Vivid will use this Apple TV’s language the next time it opens. Press the TV button twice, swipe up on Vivid, then open it again.")
        }
    }

    /// Languages are named in their own language; only System is translated.
    private func languageLabel(_ language: VividAppLanguage) -> String {
        language.nativeName ?? String(localized: "System")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
            TVSettingsSectionHeader("LANGUAGE")
            TVSettingsGroup {
                TVSettingsOptionMenu(
                    title: "Language", value: languageLabel(language),
                    detail: "Vivid follows this Apple TV’s language unless you choose one.",
                    options: VividAppLanguage.allCases.map { .init(id: $0.rawValue, label: languageLabel($0)) },
                    selection: Binding(
                        get: { language.rawValue },
                        set: {
                            guard let value = VividAppLanguage(rawValue: $0) else { return }
                            language = value
                            VividAppLanguage.save(value)
                            reopenLanguage = VividAppLanguage.needsReopen(for: value) ? value : nil
                        }
                    )
                )
                .focused(detailFocus, equals: .generalLanguage)
            }
            TVSettingsFooter("A new choice takes effect after you close Vivid in the app switcher and open it again.")

            TVSettingsSectionHeader("THEMES")
            TVSettingsGroup {
                TVSettingsOptionMenu(
                    title: "Theme", value: theme.title,
                    options: VividAppTheme.allCases.map { .init(id: $0.rawValue, label: $0.title) },
                    selection: Binding(
                        get: { theme.rawValue },
                        set: { if let value = VividAppTheme(rawValue: $0) { theme = value } }
                    )
                )
                .focused(detailFocus, equals: .generalTheme)
            }
            TVSettingsFooter("Graphite uses the charcoal background, Black uses solid black, and Native removes Vivid’s background and uses the system appearance.")

            TVSettingsSectionHeader("HOME SCREEN")

            TVSettingsGroup {
                TVSettingsPickerRow(title: "Spotlight", value: "Discovery Spotlight") {
                    showsHomeScreenSettings = true
                }
                .focused(detailFocus, equals: .generalHomeScreen)

                TVSettingsPickerRow(
                    title: "Studios & Networks",
                    value: !tmdb.isConfigured ? "Needs sign-in" : studiosNetworks.isEnabled ? "On" : "Off"
                ) { showsStudiosNetworksEditor = true }

                Button { showsHomeSectionsEditor = true } label: {
                    HStack(spacing: TVSettingsLayout.scaled(16)) {
                        TVSettingsRowLabel(title: "Home Sections")
                        Spacer(minLength: TVSettingsLayout.scaled(16))
                        Image(systemName: "chevron.right")
                            .font(.tvSettings(18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused(detailFocus, equals: .generalHomeSections)

                if MediaServerProvider.forServerID(registry.activeServerId) == .emby {
                    TVSettingsToggleRow(
                        title: "Combine Next Up with Continue Watching",
                        isOn: homeSections.combineEmbyNextUp
                    ) { homeSections.setCombineEmbyNextUp(!homeSections.combineEmbyNextUp) }
                }
                if MediaServerProvider.forServerID(registry.activeServerId) == .jellyfin {
                    TVSettingsToggleRow(
                        title: "Combine Next Up with Continue Watching",
                        isOn: homeSections.combineJellyfinNextUp
                    ) { homeSections.setCombineJellyfinNextUp(!homeSections.combineJellyfinNextUp) }
                }

            }
            if preferences.capabilityState != .checking, let message = preferences.capabilityMessage {
                TVSettingsSectionHeader("SERVER SUPPORT")
                TVSettingsFooter(message)
            }

            TVSettingsSectionHeader("POSTER CONFIGURATION")

            TVSettingsGroup {
                TVSettingsOptionMenu(
                    title: "Poster Size", value: homeCards.presentation.posterSize.title,
                    options: CardPosterSize.allCases.map { .init(id: $0.rawValue, label: $0.title) },
                    selection: Binding(
                        get: { homeCards.presentation.posterSize.rawValue },
                        set: { if let value = CardPosterSize(rawValue: $0) { homeCards.setPosterSize(value) } }
                    )
                )
                TVSettingsOptionMenu(
                    title: "Captions", value: homeCards.presentation.caption.title,
                    options: CardCaptionStyle.allCases.map { .init(id: $0.rawValue, label: $0.title) },
                    selection: Binding(
                        get: { homeCards.presentation.caption.rawValue },
                        set: { if let value = CardCaptionStyle(rawValue: $0) { homeCards.setCaptionStyle(value) } }
                    )
                )
                Button { homeCards.reset() } label: { TVSettingsRowLabel(title: "Use Profile Default") }
                    .buttonStyle(TVSettingsPaneRowStyle())

            }
            TVSettingsSectionHeader("TAB BAR")

            TVSettingsGroup {
                Button { showsMenuEditor = true } label: {
                    HStack(spacing: TVSettingsLayout.scaled(16)) {
                        TVSettingsRowLabel(title: "Customise Tab Bar")
                        Spacer(minLength: TVSettingsLayout.scaled(16))
                        Text("\(visibleMenuCount) items")
                            .font(.tvSettings(24))
                            .opacity(0.68)
                        Image(systemName: "chevron.right")
                            .font(.tvSettings(18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .disabled(!preferences.allowsEditing)
                .focused(detailFocus, equals: .generalTopMenu)
            }
            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage {
                TVSettingsFooter(message)
            }
        }
        .navigationDestination(isPresented: $showsHomeScreenSettings) {
            TVHomeScreenSettingsView()
        }
        .navigationDestination(isPresented: $showsHomeSectionsEditor) {
            TVHomeSectionsCustomizationSheet()
        }
        .navigationDestination(isPresented: $showsStudiosNetworksEditor) {
            TVStudiosNetworksSettingsView()
        }
        .navigationDestination(isPresented: $showsMenuEditor) {
            TVMenuCustomizationSheet(libraries: libraries)
        }
        .onAppear {
            homeSections.refresh()
            tmdb.reloadForCurrentProfile()
            studiosNetworks.refresh()
        }
        .onChange(of: registry.activeServerId) { _, _ in homeSections.refresh() }
        .alert("Reopen Vivid", isPresented: Binding(get: { reopenLanguage != nil }, set: { if !$0 { reopenLanguage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let reopenLanguage { reopenMessage(for: reopenLanguage) }
        }
        .task {
            await preferences.refresh()
        }
        .task(id: currentLibraryAuthority) {
            await refreshLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let authority = currentLibraryAuthority
            Task {
                async let preferencesRefresh: Void = preferences.refresh()
                async let librariesRefresh: Void = refreshLibraries(for: authority)
                _ = await (preferencesRefresh, librariesRefresh)
            }
        }
    }

    private var visibleMenuCount: Int {
        TVMenuCustomizationSheet.visibleItems(
            in: preferences.resolvedPrimaryMenuItems(),
            libraries: libraries
        ).count
    }

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }

    private var libraries: [Library] {
        librarySnapshot.availableLibraries(for: currentLibraryAuthority)
    }

    private func refreshLibraries(for authority: MainTabLibraryAuthority?) async {
        let retained = librarySnapshot.authority == authority ? librarySnapshot.libraries : []
        librarySnapshot = .init(authority: authority, libraries: retained)
        guard let authority else { return }
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
        } catch {
            // Keep the same-authority cache; a different authority already
            // failed closed above.
        }
    }

}

/// Apple TV editor for the populated rows returned by `/home/sections`.
/// Visibility is always available through the eye control; Edit reveals
/// explicit remote-friendly move buttons because tvOS has no touch drag
/// gesture. Every mutation persists immediately for the active server/profile.
private struct TVHomeSectionsCustomizationSheet: View {
    private enum FocusTarget: Hashable {
        case edit
        case done
        case moveUp(String)
        case moveDown(String)
        case visibility(String)
    }

    @State private var preferences = HomeSectionPreferences.shared
    @State private var sections: [ResolvedSection] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var isEditing = false
    @State private var isClosing = false
    @FocusState private var focusedControl: FocusTarget?
    @Namespace private var editorFocusScope
    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(28)) {
                editorControlsCard

                if arrangedSections.isEmpty, isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(.vividOnSurface)
                        Spacer()
                    }
                    .frame(height: TVSettingsLayout.scaled(160))
                } else if arrangedSections.isEmpty {
                    TVSettingsFooter(
                        loadFailed
                            ? "Vivid couldn’t refresh the Home rows. Try again when the server is reachable."
                            : "Home has no populated rows to arrange yet."
                    )
                } else {
                    TVSettingsGroup {
                        ForEach(arrangedSections) { section in
                            sectionRow(section)
                        }
                    }
                    .focusSection()

                    TVSettingsFooter(
                        isEditing
                            ? "Use the arrow buttons to move rows. The new order saves immediately."
                            : "\(preferences.visibleRowCount) of 6 rows enabled. Hide a row before showing another when all six are enabled. Hidden rows keep their settings and can still supply Spotlight."
                    )
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(72))
            .padding(.vertical, TVSettingsLayout.scaled(36))
        }
        .tvSettingsPageSurface()
        .task {
            await loadSections()
        }
        .focusScope(editorFocusScope)
        .focusSection()
        .defaultFocus($focusedControl, .done, priority: .userInitiated)
        .onAppear(perform: claimFocus)
        .onChange(of: focusedControl) { _, target in
            if target == nil, !isClosing {
                claimFocus()
            }
        }
        .onExitCommand(perform: close)
        .onDisappear { isClosing = true }
    }

    private var arrangedSections: [ResolvedSection] {
        preferences.arrangedSections(sections, includingHidden: true)
    }

    private var editorControlsCard: some View {
        TVSettingsPageHeader(
            title: Text("Home Sections"),
            subtitle: Text(isEditing ? "Move rows into your preferred order." : "Choose up to 6 Home rows. A seventh slot is reserved for Spotlight, even when hidden.")
        ) {
            Button(isEditing ? "Done Editing" : "Edit") {
                withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
                    isEditing.toggle()
                }
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle())
            .focused($focusedControl, equals: .edit)
            .disabled(arrangedSections.count < 2)

            Button("Done", action: close)
                .buttonStyle(TVHomeSectionsControlButtonStyle())
                .focused($focusedControl, equals: .done)
        }
        .focusSection()
    }

    private func sectionRow(_ section: ResolvedSection) -> some View {
        let isVisible = preferences.isVisible(section.id)
        let index = arrangedSections.firstIndex(where: { $0.id == section.id }) ?? 0

        return HStack(spacing: TVSettingsLayout.scaled(14)) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(4)) {
                Text(section.title)
                    .font(.tvSettings(26, weight: .medium))
                    .lineLimit(1)

                Text("\(section.items.count) items")
                    .font(.tvSettings(18))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .opacity(isVisible ? 1 : 0.42)

            Spacer(minLength: TVSettingsLayout.scaled(16))

            if isEditing {
                Button {
                    move(section, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .focused($focusedControl, equals: .moveUp(section.id))
                .disabled(index == 0)
                .accessibilityLabel("Move \(section.title) earlier")

                Button {
                    move(section, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .focused($focusedControl, equals: .moveDown(section.id))
                .disabled(index == arrangedSections.count - 1)
                .accessibilityLabel("Move \(section.title) later")
            }

            Button {
                withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
                    preferences.setVisible(!isVisible, sectionId: section.id)
                }
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .focused($focusedControl, equals: .visibility(section.id))
            .disabled(!isVisible && preferences.visibleRowCount >= HomeSectionPreferences.maximumVisibleRows)
            .accessibilityLabel(isVisible ? "Hide \(section.title)" : "Show \(section.title)")
        }
        .padding(.horizontal, TVSettingsLayout.scaled(24))
        .padding(.vertical, TVSettingsLayout.scaled(12))
        .background(
            Rectangle()
                .fill(TVSettingsPalette.groupFill)
        )
        .overlay {
            Rectangle()
                .strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
        }
    }

    private func move(_ section: ResolvedSection, by offset: Int) {
        var ids = arrangedSections.map(\.id)
        guard let index = ids.firstIndex(of: section.id) else { return }
        let target = index + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        let retarget: FocusTarget?
        if target == 0 {
            retarget = .moveDown(section.id)
        } else if target == ids.count - 1 {
            retarget = .moveUp(section.id)
        } else {
            retarget = nil
        }
        withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
            preferences.setOrder(ids)
            if let retarget {
                focusedControl = retarget
            }
        }
        if let retarget {
            Task { @MainActor in
                await Task.yield()
                guard isEditing, !isClosing else { return }
                focusedControl = retarget
            }
        }
    }

    /// Claim an always-enabled control inside this presented focus scope. If
    /// tvOS briefly clears the sheet's focus while resolving a swipe, the nil
    /// observer above reclaims it here instead of allowing the settings rows
    /// behind the full-screen presentation to become the active graph.
    private func claimFocus() {
        guard !isClosing else { return }
        focusedControl = .done
        Task { @MainActor in
            await Task.yield()
            guard !isClosing else { return }
            resetFocus(in: editorFocusScope)
            focusedControl = .done
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        dismiss()
    }

    private func loadSections() async {
        preferences.refresh()

        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            preferences.enforceVisibleRowLimit(in: cached.sections)
            sections = cached.sections
        }

        isLoading = sections.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard !Task.isCancelled else { return }
            preferences.enforceVisibleRowLimit(in: response.sections)
            sections = response.sections
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = sections.isEmpty
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.tvSettings(18, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(TVSettingsPalette.sectionText)
    }
}

/// Compact in-card control chrome for the Home Sections editor. The resting
/// state keeps a dark platter and bright glyph, avoiding tvOS's default white
/// bordered-button treatment that hid the eye until focus arrived.
struct TVHomeSectionsControlButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        TVHomeSectionsControlButtonBody(
            configuration: configuration,
            compact: compact
        )
    }
}

private struct TVHomeSectionsControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.tvSettings(compact ? 24 : 20, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, TVSettingsLayout.scaled(compact ? 0 : 22))
            .frame(minWidth: TVSettingsLayout.scaled(compact ? 64 : 120), minHeight: TVSettingsLayout.scaled(64), alignment: .center)
            .multilineTextAlignment(.center)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous)
                    .fill(isFocused ? Color.vividOnSurface : TVSettingsPalette.groupFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.clear : Color.vividChromeRestingBorder,
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
            .shadow(
                color: isFocused ? Color.black.opacity(0.2) : .clear,
                radius: TVSettingsLayout.scaled(16)
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        guard isEnabled else { return Color.vividSecondaryText.opacity(0.5) }
        return isFocused ? .vividBackground : .vividOnSurface
    }
}

private struct TVMenuCustomizationSheet: View {
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var utilitiesSwapped = false
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab")) private var showCalendarTab = true
    let libraries: [Library]
    @State private var preferences = UICustomizationPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(28)) {
                TVSettingsPageHeader(title: "Tab Bar", subtitle: "Choose and arrange your navigation tabs.")
                menuPreview
                sectionHeader("SEARCH & PROFILE")
                TVSettingsGroup {
                    Button { utilitiesSwapped.toggle() } label: {
                        TVSettingsRowLabel(title: Text("Swap Search and Profile"),
                            detail: Text(utilitiesSwapped ? "Profile on the left · Search on the right" : "Search on the left · Profile on the right"))
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
                TVSettingsFooter("Search and Profile stay at opposite ends. Only the tabs below move within the centre.")

                if preferences.capabilityState != .checking, let message = preferences.capabilityMessage {
                    TVSettingsFooter(message)
                }

                if preferences.primaryMenuUsesDeviceOverride {
                    TVSettingsFooter("This Apple TV has an older tab-bar override.")
                }

                sectionHeader("VISIBLE DESTINATIONS")

                TVSettingsGroup {
                    ForEach(visibleItems) { item in
                        visibleRow(item)
                    }
                }
                .focusSection()
                .disabled(!familyMenuMutationsEnabled)

                if !hiddenBuiltins.isEmpty {
                    sectionHeader("HIDDEN DESTINATIONS")
                    TVSettingsGroup {
                        ForEach(hiddenBuiltins) { item in
                            Button {
                                persistVisibleItems(visibleItems + [item])
                            } label: {
                                HStack(spacing: TVSettingsLayout.scaled(18)) {
                                    Image(systemName: "eye.slash")
                                    Text("Show \(item.title)")
                                    Spacer()
                                }
                                .font(.tvSettings(26, weight: .medium))
                            }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        }
                    }
                    .focusSection()
                    .disabled(!familyMenuMutationsEnabled)
                }

                // Calendar isn't reordered with the destinations above: when
                // it's shown, it always sits just after For You, or at the
                // end when For You is hidden.
                sectionHeader("CALENDAR")
                TVSettingsGroup {
                    HStack(spacing: TVSettingsLayout.scaled(12)) {
                        TVSettingsRowLabel(
                            title: Text("Calendar"),
                            detail: Text(!showCalendarTab ? "Hidden from the tab bar."
                                : visibleItems.contains(.builtin(.forYou)) ? "Shown in the tab bar, just after For You."
                                : "Shown at the end of the tab bar.")
                        )
                        Spacer(minLength: TVSettingsLayout.scaled(12))
                        Button {
                            showCalendarTab.toggle()
                        } label: {
                            Image(systemName: showCalendarTab ? "eye" : "eye.slash")
                                .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
                        }
                        .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                        .accessibilityLabel(showCalendarTab ? "Hide Calendar" : "Show Calendar")
                    }
                    .padding(.horizontal, TVSettingsLayout.scaled(24))
                    .padding(.vertical, TVSettingsLayout.scaled(12))
                    .background(Rectangle().fill(TVSettingsPalette.groupFill))
                    .overlay { Rectangle().strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1) }
                }
                .focusSection()

                TVSettingsFooter("Changes save automatically. Home stays visible; press Back to return.")
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(72))
            .padding(.vertical, TVSettingsLayout.scaled(36))
        }
        .tvSettingsPageSurface()
        .onExitCommand { dismiss() }
    }

    private var menuPreview: some View {
        HStack(spacing: TVSettingsLayout.scaled(8)) {
            Image(systemName: utilitiesSwapped ? "person.crop.circle.fill" : "magnifyingglass")
                .frame(width: TVSettingsLayout.scaled(42))
            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: TVSettingsLayout.scaled(24))
            ForEach(previewTabs) { tab in
                Text(tab.title)
                    .font(.tvSettings(20, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, TVSettingsLayout.scaled(12)).padding(.vertical, TVSettingsLayout.scaled(9))
                    .foregroundStyle(tab.isHome ? Color.black : Color.white)
                    .background(tab.isHome ? Color.white : Color.clear, in: Capsule())
            }
            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: TVSettingsLayout.scaled(24))
            Image(systemName: utilitiesSwapped ? "magnifyingglass" : "person.crop.circle.fill")
                .frame(width: TVSettingsLayout.scaled(42))
        }
        .font(.tvSettings(24))
        .modifier(TVTopMenuGlassChrome())
        .frame(maxWidth: .infinity)
        .padding(.vertical, TVSettingsLayout.scaled(28))
        .allowsHitTesting(false)
        .accessibilityLabel("Tab bar preview")
    }

    /// One tab in the preview. Home is found by its item, not its title,
    /// which is in the app's language.
    private struct PreviewTab: Identifiable {
        let id: String
        let title: String
        let isHome: Bool
    }

    /// The bar as it will look, with Calendar in its fixed place.
    private var previewTabs: [PreviewTab] {
        var tabs = visibleItems.map { PreviewTab(id: $0.id, title: $0.title, isHome: $0.isHome) }
        if showCalendarTab {
            let calendar = PreviewTab(id: "calendar", title: String(localized: "Calendar"), isHome: false)
            if let forYou = visibleItems.firstIndex(of: .builtin(.forYou)) {
                tabs.insert(calendar, at: forYou + 1)
            } else {
                tabs.append(calendar)
            }
        }
        return tabs
    }

    private var visibleItems: [PrimaryMenuItem] {
        Self.visibleItems(
            in: preferences.resolvedPrimaryMenuItems(),
            libraries: libraries
        )
    }

    static func visibleItems(
        in items: [PrimaryMenuItem],
        libraries: [Library]
    ) -> [PrimaryMenuItem] {
        func hasLibrary(_ type: TVLibraryTabType) -> Bool {
            libraries.contains(where: { type.matches($0) })
        }
        return items.filter { item in
            switch item {
            case .builtin(.movies): return hasLibrary(.movies)
            case .builtin(.series): return hasLibrary(.series)
            case .library, .section, .collection: return false
            case .builtin(.home), .builtin(.forYou): return true
            }
        }
    }

    private var familyMenuMutationsEnabled: Bool {
        tvCustomizationMutationIsEnabled(
            allowsEditing: preferences.allowsEditing,
            usesDeviceMenuOverride: preferences.primaryMenuUsesDeviceOverride,
            changesFamilyMenu: true
        )
    }

    private var hiddenBuiltins: [PrimaryMenuItem] {
        let visibleIds = Set(visibleItems.map(\.id))
        return builtinCandidates.filter { !visibleIds.contains($0.id) }
    }

    private var builtinCandidates: [PrimaryMenuItem] {
        var items: [PrimaryMenuItem] = [.builtin(.home)]
        for type in TVLibraryTabType.allCases where hasLibrary(type) {
            let builtin: PrimaryMenuBuiltin
            switch type {
            case .movies: builtin = .movies
            case .series: builtin = .series
            }
            items.append(.builtin(builtin))
        }
        items.append(contentsOf: [.builtin(.forYou)])
        return items
    }

    private func visibleRow(_ item: PrimaryMenuItem) -> some View {
        let index = visibleItems.firstIndex(where: { $0.id == item.id }) ?? 0
        return HStack(spacing: TVSettingsLayout.scaled(12)) {
            TVSettingsRowLabel(title: Text(item.title), detail: Text("Shown in the tab bar. Use the arrows to change its position."))
            Spacer(minLength: TVSettingsLayout.scaled(12))

            Button {
                move(item, by: -1)
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .disabled(index == 0)
            .accessibilityLabel("Move \(item.title) earlier")

            Button {
                move(item, by: 1)
            } label: {
                Image(systemName: "arrow.down")
                    .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .disabled(index == visibleItems.count - 1)
            .accessibilityLabel("Move \(item.title) later")

            if !item.isHome {
                Button {
                    hide(item)
                } label: {
                    Image(systemName: "eye")
                        .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .accessibilityLabel("Hide \(item.title)")
            }
        }
        .padding(.horizontal, TVSettingsLayout.scaled(24))
        .padding(.vertical, TVSettingsLayout.scaled(12))
        .background(
            Rectangle()
                .fill(TVSettingsPalette.groupFill)
        )
        .overlay {
            Rectangle()
                .strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
        }
    }

    private func move(_ item: PrimaryMenuItem, by offset: Int) {
        var items = visibleItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        persistVisibleItems(items)
    }

    private func hide(_ item: PrimaryMenuItem) {
        guard !item.isHome else { return }
        persistVisibleItems(visibleItems.filter { $0.id != item.id })
    }

    /// Weave the edited, focus-visible rows back through the complete synced
    /// menu. Section/collection targets and temporarily unavailable libraries
    /// are not renderable roots on Apple TV yet, but must survive an unrelated
    /// reorder so another TV-family client does not lose them.
    private func persistVisibleItems(_ updatedVisibleItems: [PrimaryMenuItem]) {
        let currentlyVisibleIds = Set(visibleItems.map(\.id))
        var replacements = updatedVisibleItems.makeIterator()
        var result: [PrimaryMenuItem] = []

        for item in preferences.resolvedPrimaryMenuItems() {
            if currentlyVisibleIds.contains(item.id) {
                if let replacement = replacements.next() {
                    result.append(replacement)
                }
            } else {
                result.append(item)
            }
        }
        while let remaining = replacements.next() {
            result.append(remaining)
        }
        preferences.setPrimaryMenuItems(result)
    }

    private func hasLibrary(_ type: TVLibraryTabType) -> Bool {
        libraries.contains(where: { type.matches($0) })
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.tvSettings(18, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(TVSettingsPalette.sectionText)
    }
}
#endif
