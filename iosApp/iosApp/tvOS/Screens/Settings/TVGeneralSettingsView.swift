#if os(tvOS)
import SwiftUI

/// Family-synced tvOS interface preferences. Every control is a native focus
/// target; the menu editor changes data only on Select and never intercepts
/// directional movement, preserving the stable focus graph described in
/// `docs/apple-tv-focus.md`.
struct TVGeneralSettingsPane: View {
    @State private var homeSections = HomeSectionPreferences.shared
    @State private var preferences = UICustomizationPreferences.shared
    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var activePicker: PickerKind?
    @State private var showsHomeSectionsEditor = false
    @State private var showsHomeScreenSettings = false
    @State private var showsMenuEditor = false
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("HOME SCREEN")

            TVSettingsGroup {
                TVSettingsPickerRow(title: "Home Screen", value: "Discovery Spotlight") {
                    showsHomeScreenSettings = true
                }
                .focused(detailFocus, equals: .generalHomeScreen)

                Button { showsHomeSectionsEditor = true } label: {
                    HStack(spacing: 16) {
                        TVSettingsRowLabel(title: "Home Sections")
                        Spacer(minLength: 16)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
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

            }
            if preferences.capabilityState != .checking, let message = preferences.capabilityMessage {
                TVSettingsSectionHeader("SERVER SUPPORT")
                TVSettingsFooter(message)
            }

            TVSettingsSectionHeader("POSTER CONFIGURATION")

            TVSettingsGroup {
                TVSettingsPickerRow(title: "Poster Size", value: homeCards.presentation.posterSize.title) {
                    activePicker = .posterSize
                }
                TVSettingsPickerRow(title: "Captions", value: homeCards.presentation.caption.title) {
                    activePicker = .caption
                }
                Button { homeCards.reset() } label: { TVSettingsRowLabel(title: "Use Profile Default") }
                    .buttonStyle(TVSettingsPaneRowStyle())

            }
            TVSettingsSectionHeader("TAB BAR")

            TVSettingsGroup {
                Button { showsMenuEditor = true } label: {
                    HStack(spacing: 16) {
                        TVSettingsRowLabel(title: "Customise Tab Bar")
                        Spacer(minLength: 16)
                        Text("\(visibleMenuCount) items")
                            .font(.system(size: 24))
                            .opacity(0.68)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
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
        .fullScreenCover(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
        .fullScreenCover(isPresented: $showsHomeScreenSettings) {
            TVHomeScreenSettingsView()
        }
        .fullScreenCover(isPresented: $showsHomeSectionsEditor) {
            TVHomeSectionsCustomizationSheet()
        }
        .fullScreenCover(isPresented: $showsMenuEditor) {
            TVMenuCustomizationSheet(libraries: libraries)
        }
        .onAppear { homeSections.refresh() }
        .onChange(of: registry.activeServerId) { _, _ in homeSections.refresh() }
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

    @ViewBuilder
    private func pickerSheet(for picker: PickerKind) -> some View {
        switch picker {
        case .posterSize:
            TVSettingsPickerSheet(
                title: "Poster Size",
                options: CardPosterSize.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                },
                selection: Binding(
                    get: { homeCards.presentation.posterSize.rawValue },
                    set: { value in
                        guard let size = CardPosterSize(rawValue: value) else { return }
                        homeCards.setPosterSize(size)
                    }
                )
            )
        case .caption:
            TVSettingsPickerSheet(
                title: "Card Captions",
                options: CardCaptionStyle.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                },
                selection: Binding(
                    get: { homeCards.presentation.caption.rawValue },
                    set: { value in
                        guard let style = CardCaptionStyle(rawValue: value) else { return }
                        homeCards.setCaptionStyle(style)
                    }
                )
            )
        }
    }

    private enum PickerKind: String, Identifiable {
        case posterSize
        case caption
        var id: String { rawValue }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    sectionHeader("HOME SECTIONS")

                    editorControlsCard

                    if arrangedSections.isEmpty, isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(.vividOnSurface)
                            Spacer()
                        }
                        .frame(height: 160)
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
                                : "Open eye: visible on Home. Closed eye: hidden. Hidden rows leave no gap—the next visible row takes the same Home position."
                        )
                    }
                }
                .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 36)
            }
            .navigationTitle("Home Sections")
            .background(Color.vividBackground.ignoresSafeArea())
            .task {
                await loadSections()
            }
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Home Sections")
                    .font(.system(size: 26, weight: .medium))

                Text(isEditing ? "Move rows into your preferred order." : "Choose which rows appear on Home.")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.vividSecondaryText)
            }

            Spacer(minLength: 24)

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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(TVSettingsPalette.groupFill)
        )
        .overlay {
            Rectangle()
                .strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
        }
        .focusSection()
    }

    private func sectionRow(_ section: ResolvedSection) -> some View {
        let isVisible = preferences.isVisible(section.id)
        let index = arrangedSections.firstIndex(where: { $0.id == section.id }) ?? 0

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)

                Text("\(section.items.count) item\(section.items.count == 1 ? "" : "s")")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .opacity(isVisible ? 1 : 0.42)

            Spacer(minLength: 16)

            if isEditing {
                Button {
                    move(section, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .focused($focusedControl, equals: .moveUp(section.id))
                .disabled(index == 0)
                .accessibilityLabel("Move \(section.title) earlier")

                Button {
                    move(section, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: 44, height: 44)
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
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .focused($focusedControl, equals: .visibility(section.id))
            .accessibilityLabel(isVisible ? "Hide \(section.title)" : "Show \(section.title)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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
            sections = cached.sections.filter { !$0.items.isEmpty }
        }

        isLoading = sections.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard !Task.isCancelled else { return }
            sections = response.sections.filter { !$0.items.isEmpty }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = sections.isEmpty
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .rounded))
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
            .font(.system(size: compact ? 24 : 20, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 0 : 22)
            .frame(minWidth: 64, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.vividOnSurface : TVSettingsPalette.groupFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.clear : Color.vividChromeRestingBorder,
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
            .shadow(
                color: isFocused ? Color.black.opacity(0.2) : .clear,
                radius: 16
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
    let libraries: [Library]
    @State private var preferences = UICustomizationPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    menuPreview
                    sectionHeader("SEARCH & PROFILE")
                    TVSettingsGroup {
                        Button { utilitiesSwapped.toggle() } label: {
                            TVSettingsRowLabel(title: "Swap Search and Profile",
                                detail: utilitiesSwapped ? "Profile on the left · Search on the right" : "Search on the left · Profile on the right")
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
                                    HStack(spacing: 18) {
                                        Image(systemName: "eye.slash")
                                        Text("Show \(item.title)")
                                        Spacer()
                                    }
                                    .font(.system(size: 26, weight: .medium))
                                }
                                .buttonStyle(TVSettingsPaneRowStyle())
                            }
                        }
                        .focusSection()
                        .disabled(!familyMenuMutationsEnabled)
                    }

                    TVSettingsFooter("Changes save automatically. Home stays visible; press Back to return.")
                }
                .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 36)
            }
            .navigationTitle("Customise Tab Bar")
            .background(Color.vividBackground.ignoresSafeArea())
        }
        .background(Color.black.ignoresSafeArea())
        .onExitCommand { dismiss() }
    }

    private var menuPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: utilitiesSwapped ? "person.crop.circle.fill" : "magnifyingglass")
                .frame(width: 42)
            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24)
            ForEach(visibleItems) { item in
                Text(item.title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(item == .builtin(.home) ? Color.black : Color.white)
                    .background(item == .builtin(.home) ? Color.white : Color.clear, in: Capsule())
            }
            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24)
            Image(systemName: utilitiesSwapped ? "magnifyingglass" : "person.crop.circle.fill")
                .frame(width: 42)
        }
        .font(.system(size: 24))
        .modifier(TVTopMenuGlassChrome())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .allowsHitTesting(false)
        .accessibilityLabel("Tab bar preview")
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
        return HStack(spacing: 12) {
            TVSettingsRowLabel(title: item.title, detail: "Shown in the tab bar. Use the arrows to change its position.")
            Spacer(minLength: 12)

            Button {
                move(item, by: -1)
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .disabled(index == 0)
            .accessibilityLabel("Move \(item.title) earlier")

            Button {
                move(item, by: 1)
            } label: {
                Image(systemName: "arrow.down")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .disabled(index == visibleItems.count - 1)
            .accessibilityLabel("Move \(item.title) later")

            if !item.isHome {
                Button {
                    hide(item)
                } label: {
                    Image(systemName: "eye")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .accessibilityLabel("Hide \(item.title)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(TVSettingsPalette.sectionText)
    }
}
#endif
