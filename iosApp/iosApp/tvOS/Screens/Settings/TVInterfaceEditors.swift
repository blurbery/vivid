#if os(tvOS)
import SwiftUI

extension TVSettingsView {
    /// The layout every pushed editor page shares.
    fileprivate struct EditorPage<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(28)) {
                    content
                }
                .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, TVSettingsLayout.scaled(72))
                .padding(.vertical, TVSettingsLayout.scaled(36))
            }
            .tvSettingsPageSurface()
        }
    }

    /// The rows behind a group's own rows in the editors.
    fileprivate struct EditorRowBackground: View {
        var body: some View {
            Rectangle().fill(TVSettingsPalette.groupFill)
            Rectangle().strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
        }
    }

    /// The small square arrow and eye buttons.
    fileprivate struct EditorSymbolButton: View {
        let systemName: String
        let label: Text
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .accessibilityLabel(label)
        }
    }

    // MARK: - Home Sections

    /// General > Home Sections: which Home rows show, and their order.
    struct HomeSectionsEditorPage: View {
        private enum EditorFocus: Hashable {
            case done, edit
            case up(String), down(String), eye(String)
        }

        @State private var preferences = HomeSectionPreferences.shared
        @State private var sections: [ResolvedSection] = []
        @State private var isLoading = false
        @State private var failed = false
        @State private var isEditing = false
        @State private var isClosing = false
        @FocusState private var focus: EditorFocus?
        @Namespace private var scope
        @Environment(\.resetFocus) private var resetFocus
        @Environment(\.dismiss) private var dismiss

        private var rows: [ResolvedSection] { preferences.arrangedSections(sections, includingHidden: true) }

        var body: some View {
            let arranged = rows
            EditorPage {
                TVSettingsPageHeader(title: "Home Sections",
                                     subtitle: isEditing ? "Move rows into your preferred order."
                                                         : "Choose up to 6 Home rows. A seventh slot is reserved for Spotlight, even when hidden.") {
                    Button(isEditing ? "Done Editing" : "Edit") {
                        withAnimation(.easeOut(duration: 0.12)) { isEditing.toggle() }
                    }
                    .buttonStyle(TVHomeSectionsControlButtonStyle())
                    .disabled(arranged.count < 2)
                    .focused($focus, equals: .edit)
                    Button("Done", action: close)
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .done)
                }
                .focusSection()
                if isLoading && arranged.isEmpty {
                    ProgressView()
                        .tint(Color.vividOnSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: TVSettingsLayout.scaled(160))
                } else if arranged.isEmpty {
                    TVSettingsFooter(failed
                                     ? "Vivid couldn’t refresh the Home rows. Try again when the server is reachable."
                                     : "Home has no populated rows to arrange yet.")
                } else {
                    TVSettingsGroup {
                        ForEach(Array(arranged.enumerated()), id: \.element.id) { index, section in
                            row(section, index: index, count: arranged.count)
                        }
                    }
                    .focusSection()
                    TVSettingsFooter(isEditing
                                     ? "Use the arrow buttons to move rows. The new order saves immediately."
                                     : "\(preferences.visibleRowCount) of 6 rows enabled. Hide a row before showing another when all six are enabled. Hidden rows keep their settings and can still supply Spotlight.")
                }
            }
            .focusScope(scope)
            .defaultFocus($focus, .done)
            .onAppear(perform: focusDone)
            .onChange(of: focus) { _, newFocus in
                if newFocus == nil && !isClosing { focusDone() }
            }
            .onExitCommand(perform: close)
            .onDisappear { isClosing = true }
            .task { await load() }
        }

        private func row(_ section: ResolvedSection, index: Int, count: Int) -> some View {
            let visible = preferences.isVisible(section.id)
            return HStack(spacing: TVSettingsLayout.scaled(14)) {
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(4)) {
                    Text(section.title)
                        .font(.tvSettings(26, weight: .medium))
                        .lineLimit(1)
                    Text("\(section.totalCount ?? section.items.count) items")
                        .font(.tvSettings(18))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                .opacity(visible ? 1 : 0.42)
                Spacer(minLength: TVSettingsLayout.scaled(16))
                if isEditing {
                    EditorSymbolButton(systemName: "arrow.up", label: Text("Move \(section.title) earlier")) {
                        move(section.id, by: -1)
                    }
                    .disabled(index == 0)
                    .focused($focus, equals: .up(section.id))
                    EditorSymbolButton(systemName: "arrow.down", label: Text("Move \(section.title) later")) {
                        move(section.id, by: 1)
                    }
                    .disabled(index == count - 1)
                    .focused($focus, equals: .down(section.id))
                }
                EditorSymbolButton(systemName: visible ? "eye" : "eye.slash",
                                   label: visible ? Text("Hide \(section.title)") : Text("Show \(section.title)")) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        preferences.setVisible(!visible, sectionId: section.id)
                    }
                }
                .disabled(!visible && preferences.visibleRowCount >= HomeSectionPreferences.maximumVisibleRows)
                .focused($focus, equals: .eye(section.id))
            }
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.vertical, TVSettingsLayout.scaled(12))
            .background { EditorRowBackground() }
        }

        private func move(_ id: String, by offset: Int) {
            var ids = rows.map(\.id)
            guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
            ids.swapAt(index, index + offset)
            let landed = index + offset
            let target: EditorFocus? = landed == 0 ? .down(id) : landed == ids.count - 1 ? .up(id) : nil
            withAnimation {
                preferences.setOrder(ids)
                if let target { focus = target }
            }
            if let target {
                Task { @MainActor in
                    if isEditing && !isClosing { focus = target }
                }
            }
        }

        private func focusDone() {
            focus = .done
            Task { @MainActor in
                resetFocus(in: scope)
                focus = .done
            }
        }

        private func close() {
            guard !isClosing else { return }
            isClosing = true
            dismiss()
        }

        private func load() async {
            preferences.refresh()
            if let cached = ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) {
                preferences.enforceVisibleRowLimit(in: cached.sections)
                sections = cached.sections
            }
            isLoading = sections.isEmpty
            defer { isLoading = false }
            do {
                let response = try await StartupContentPrefetcher.fetchHomeSections()
                guard !Task.isCancelled else { return }
                preferences.enforceVisibleRowLimit(in: response.sections)
                sections = response.sections
            } catch {
                if !Task.isCancelled && sections.isEmpty { failed = true }
            }
        }
    }

    // MARK: - Tab bar

    /// General > Customise Tab Bar on Apple TV.
    struct TabBarEditorPage: View {
        let libraries: [Library]

        @State private var preferences = UICustomizationPreferences.shared
        @AppStorage private var swapsUtilities: Bool
        @AppStorage private var showsCalendar: Bool
        @Environment(\.dismiss) private var dismiss

        init(libraries: [Library]) {
            self.libraries = libraries
            _swapsUtilities = AppStorage(wrappedValue: false, MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities"))
            _showsCalendar = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab"))
        }

        private var visibleItems: [PrimaryMenuItem] {
            TVSettingsView.tabBarItems(preferences.resolvedPrimaryMenuItems(), libraries: libraries)
        }

        private var hiddenItems: [PrimaryMenuItem] {
            let visible = visibleItems
            var candidates: [PrimaryMenuItem] = [.builtin(.home)]
            if TVSettingsView.tabBarShows(.builtin(.movies), libraries: libraries) { candidates.append(.builtin(.movies)) }
            if TVSettingsView.tabBarShows(.builtin(.series), libraries: libraries) { candidates.append(.builtin(.series)) }
            candidates.append(.builtin(.forYou))
            return candidates.filter { !visible.contains($0) }
        }

        private var showsForYou: Bool { visibleItems.contains(.builtin(.forYou)) }

        private var canEdit: Bool {
            tvCustomizationMutationIsEnabled(allowsEditing: preferences.allowsEditing,
                                             usesDeviceMenuOverride: preferences.primaryMenuUsesDeviceOverride,
                                             changesFamilyMenu: true)
        }

        var body: some View {
            EditorPage {
                TVSettingsPageHeader(title: "Tab Bar", subtitle: "Choose and arrange your navigation tabs.")
                preview
                searchAndProfile
                visibleSection
                if !hiddenItems.isEmpty { hiddenSection }
                calendarSection
                TVSettingsFooter("Changes save automatically. Home stays visible; press Back to return.")
            }
            .onExitCommand { dismiss() }
        }

        private func heading(_ title: LocalizedStringKey) -> some View {
            Text(title)
                .font(.tvSettings(18, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(TVSettingsPalette.sectionText)
        }

        // MARK: Preview

        private var preview: some View {
            let visible = visibleItems
            var tabs: [(id: String, title: String, isHome: Bool)] = visible.map { ($0.id, $0.title, $0.isHome) }
            if showsCalendar {
                let calendar = (id: "vivid.calendar", title: AppTab.calendar.title, isHome: false)
                if let forYou = visible.firstIndex(of: .builtin(.forYou)) {
                    tabs.insert(calendar, at: forYou + 1)
                } else {
                    tabs.append(calendar)
                }
            }
            let shownTabs = tabs
            return HStack(spacing: TVSettingsLayout.scaled(8)) {
                Image(systemName: swapsUtilities ? "person.crop.circle.fill" : "magnifyingglass")
                    .frame(width: TVSettingsLayout.scaled(42))
                previewDivider
                ForEach(shownTabs.indices, id: \.self) { index in
                    let tab = shownTabs[index]
                    Text(verbatim: tab.title)
                        .font(.tvSettings(20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, TVSettingsLayout.scaled(12))
                        .padding(.vertical, TVSettingsLayout.scaled(9))
                        .foregroundStyle(tab.isHome ? Color.black : Color.white)
                        .background(tab.isHome ? Color.white : Color.clear, in: Capsule())
                }
                previewDivider
                Image(systemName: swapsUtilities ? "magnifyingglass" : "person.crop.circle.fill")
            }
            .font(.tvSettings(24))
            .modifier(TVTopMenuGlassChrome())
            .frame(maxWidth: .infinity)
            .padding(.vertical, TVSettingsLayout.scaled(28))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tab bar preview")
        }

        private var previewDivider: some View {
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: 1, height: TVSettingsLayout.scaled(24))
        }

        // MARK: Groups

        private var searchAndProfile: some View {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                heading("SEARCH & PROFILE")
                TVSettingsGroup {
                    Button { swapsUtilities.toggle() } label: {
                        TVSettingsRowLabel(title: "Swap Search and Profile",
                                           detail: swapsUtilities ? "Profile on the left · Search on the right"
                                                                  : "Search on the left · Profile on the right")
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
            }
        }

        private var visibleSection: some View {
            let visible = visibleItems
            return VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                heading("VISIBLE DESTINATIONS")
                TVSettingsGroup {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: TVSettingsLayout.scaled(12)) {
                            TVSettingsRowLabel(title: Text(item.title),
                                               detail: Text("Shown in the tab bar. Use the arrows to change its position."))
                            Spacer(minLength: TVSettingsLayout.scaled(12))
                            EditorSymbolButton(systemName: "arrow.up", label: Text("Move \(item.title) earlier")) {
                                swap(index, index - 1, in: visible)
                            }
                            .disabled(index == 0)
                            EditorSymbolButton(systemName: "arrow.down", label: Text("Move \(item.title) later")) {
                                swap(index, index + 1, in: visible)
                            }
                            .disabled(index == visible.count - 1)
                            if !item.isHome {
                                EditorSymbolButton(systemName: "eye", label: Text("Hide \(item.title)")) {
                                    save(visible.filter { $0 != item })
                                }
                            }
                        }
                        .padding(.horizontal, TVSettingsLayout.scaled(24))
                        .padding(.vertical, TVSettingsLayout.scaled(12))
                        .background { EditorRowBackground() }
                    }
                }
                .focusSection()
                .disabled(!canEdit)
            }
        }

        private var hiddenSection: some View {
            let visible = visibleItems
            return VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                heading("HIDDEN DESTINATIONS")
                TVSettingsGroup {
                    ForEach(hiddenItems) { item in
                        Button { save(visible + [item]) } label: {
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
                .disabled(!canEdit)
            }
        }

        private var calendarSection: some View {
            let detail: LocalizedStringResource = !showsCalendar ? "Hidden from the tab bar."
                : showsForYou ? "Shown in the tab bar, just after For You." : "Shown at the end of the tab bar."
            return VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                heading("CALENDAR")
                TVSettingsGroup {
                    HStack(spacing: TVSettingsLayout.scaled(12)) {
                        TVSettingsRowLabel(title: "Calendar", detail: detail)
                        EditorSymbolButton(systemName: showsCalendar ? "eye" : "eye.slash",
                                           label: showsCalendar ? Text("Hide Calendar") : Text("Show Calendar")) {
                            showsCalendar.toggle()
                        }
                    }
                    .padding(.horizontal, TVSettingsLayout.scaled(24))
                    .padding(.vertical, TVSettingsLayout.scaled(12))
                    .background { EditorRowBackground() }
                }
                .focusSection()
            }
        }

        // MARK: Saving

        private func swap(_ first: Int, _ second: Int, in visible: [PrimaryMenuItem]) {
            guard visible.indices.contains(first), visible.indices.contains(second) else { return }
            var items = visible
            items.swapAt(first, second)
            save(items)
        }

        /// Saves a new visible list. Items this editor doesn't show keep
        /// their places; the places of shown items are refilled in order.
        private func save(_ newVisible: [PrimaryMenuItem]) {
            var remaining = newVisible[...]
            var menu: [PrimaryMenuItem] = []
            for item in preferences.resolvedPrimaryMenuItems() {
                if TVSettingsView.tabBarShows(item, libraries: libraries) {
                    if let next = remaining.popFirst() { menu.append(next) }
                } else {
                    menu.append(item)
                }
            }
            menu.append(contentsOf: remaining)
            preferences.setPrimaryMenuItems(menu)
        }
    }

    // MARK: - Home Screen

    /// General > Spotlight: which Home rows feed the discovery spotlight.
    struct HomeScreenPage: View {
        @State private var spotlight = TVHomeSpotlightPreferences.shared
        @State private var sections: [ResolvedSection] = []
        @State private var isLoading = true
        @State private var failed = false
        @FocusState private var doneFocused: Bool
        @Environment(\.dismiss) private var dismiss

        private var selectedCount: Int { spotlight.selectedRowIDs?.count ?? 0 }

        var body: some View {
            let sources = spotlight.sourceSections(from: sections)
            EditorPage {
                TVSettingsPageHeader(title: "Home Screen", subtitle: "Choose up to 3 spotlight rows. \(selectedCount) selected.") {
                    Button("Done") { dismiss() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($doneFocused)
                }
                if isLoading && sections.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if failed && sections.isEmpty {
                    TVSettingsFooter("Couldn’t load your Home rows.")
                    Button("Try Again") { Task { await load() } }
                } else {
                    TVSettingsGroup {
                        ForEach(sources) { section in
                            spotlightRow(id: section.id, title: section.title)
                        }
                        ForEach(missingIDs(sources), id: \.self) { id in
                            spotlightRow(id: id, title: String(localized: "Unavailable Home row \u{2014} remove from spotlight"))
                        }
                    }
                    TVSettingsFooter(sources.isEmpty
                                     ? "Your Home rows will appear here when your server has media to show."
                                     : selectedCount >= 3
                                     ? "To choose a different row, turn off one of the selected rows first."
                                     : "Choose no rows to hide the spotlight. Changes save automatically.")
                }
            }
            .defaultFocus($doneFocused, true)
            .onExitCommand { dismiss() }
            .task { await load() }
        }

        private func missingIDs(_ sources: [ResolvedSection]) -> [String] {
            (spotlight.selectedRowIDs ?? []).filter { id in !sources.contains { $0.id == id } }
        }

        private func spotlightRow(id: String, title: String) -> some View {
            let selected = spotlight.selectedRowIDs?.contains(id) == true
            return Button { spotlight.toggle(id) } label: {
                HStack(spacing: TVSettingsLayout.scaled(18)) {
                    TVSettingsRowLabel(title: Text(title), detail: nil)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .frame(width: TVSettingsLayout.scaled(44), height: TVSettingsLayout.scaled(44))
                }
                .font(.tvSettings(26))
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
            .accessibilityHint(!selected && selectedCount >= 3
                               ? Text("Three rows are selected. Turn one off to select this row.")
                               : Text("Toggle spotlight source"))
        }

        /// The rows that can feed the spotlight: those with items, and those
        /// hidden on Home.
        private func spotlightCandidates(_ rows: [ResolvedSection]) -> [ResolvedSection] {
            let home = HomeSectionPreferences.shared
            return rows.filter { !$0.items.isEmpty || !home.isVisible($0.id) }
        }

        private func load() async {
            spotlight.refresh()
            if let cached = ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) {
                sections = spotlightCandidates(cached.sections)
                spotlight.initializeIfNeeded(from: sections)
            }
            isLoading = sections.isEmpty
            failed = false
            defer { isLoading = false }
            do {
                let response = try await StartupContentPrefetcher.fetchHomeSections()
                guard !Task.isCancelled else { return }
                sections = spotlightCandidates(response.sections)
                spotlight.initializeIfNeeded(from: sections)
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
#endif
