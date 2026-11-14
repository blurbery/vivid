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
                .icon(.symbol("rectangle.3.group"))
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
                    Text("\(section.items.count) items")
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

    /// The real tab bar's notch, hanging from the top of a small stage and
    /// playing itself: it opens, moves to the next tab, chooses it and
    /// closes around it, then carries on from there. Drawn with the bar's
    /// own views, so it follows the bar's design. It never takes focus.
    fileprivate struct TabBarPreview: View {
        struct Tab: Hashable {
            let id: String
            let title: String
            let symbol: String
        }

        let tabs: [Tab]
        let swapsUtilities: Bool

        @State private var selectedID: String?
        /// The tab drawn as focused; nil while the bar is closed.
        @State private var focusedID: String?
        @Namespace private var highlight
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private struct LoopKey: Hashable {
            let ids: [String]
            let swapsUtilities: Bool
            let reduceMotion: Bool
        }

        private var selected: String? {
            tabs.contains { $0.id == selectedID } ? selectedID : tabs.first?.id
        }

        /// With Reduce Motion the bar stays open on one tab, so every tab
        /// and its place still show. With a single tab there is nothing to
        /// open, so it stays closed either way.
        private var shownFocus: String? {
            guard tabs.count > 1 else { return nil }
            return reduceMotion ? selected : focusedID
        }

        private var stage: RoundedRectangle {
            RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(22), style: .continuous)
        }

        var body: some View {
            let shownFocus = shownFocus
            let selected = selected
            HStack(spacing: VividTheme.Skyline.tabSpacing) {
                utility(search: !swapsUtilities)
                TVTopMenuDivider()
                ForEach(tabs, id: \.id) { tab in
                    if shownFocus != nil || tab.id == selected {
                        TVTopMenuTabLabel(symbol: tab.symbol, title: tab.title,
                                          isSelected: tab.id == selected,
                                          isFocused: tab.id == shownFocus,
                                          barHasFocus: shownFocus != nil,
                                          highlight: highlight)
                            .transition(TVTopMenuMotion.tabTransition(reduceMotion: reduceMotion))
                    }
                }
                TVTopMenuDivider()
                utility(search: swapsUtilities)
            }
            .fixedSize()
            .modifier(TVTopMenuNotchChrome())
            .frame(maxWidth: .infinity)
            .frame(height: TVSettingsLayout.scaled(112), alignment: .top)
            .background {
                stage.fill(TVSettingsPalette.groupFill)
                stage.strokeBorder(Color.vividChromeRestingBorder, lineWidth: 1)
            }
            .clipShape(stage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tab bar preview")
            .task(id: LoopKey(ids: tabs.map(\.id), swapsUtilities: swapsUtilities, reduceMotion: reduceMotion)) { await play() }
        }

        @ViewBuilder
        private func utility(search: Bool) -> some View {
            if search {
                TVTopMenuSearchLabel(isFocused: false, highlight: highlight)
            } else {
                TVTopMenuProfileLabel(profile: CurrentProfileStore.shared.profile, isFocused: false, highlight: highlight)
            }
        }

        /// Runs until the tabs or the Search and Profile ends change, or the
        /// page goes away.
        private func play() async {
            focusedID = nil
            guard !reduceMotion, tabs.count > 1 else { return }
            let open = TVTopMenuMotion.tabs(reduceMotion: false)
            do {
                while true {
                    try await Task.sleep(for: .seconds(1.2))
                    guard let current = selected,
                          let index = tabs.firstIndex(where: { $0.id == current }) else { return }
                    withAnimation(open) { focusedID = current }
                    try await Task.sleep(for: .seconds(1))
                    let next = tabs[(index + 1) % tabs.count].id
                    withAnimation(open) { focusedID = next }
                    try await Task.sleep(for: .seconds(1.1))
                    withAnimation(TVTopMenuMotion.close) {
                        selectedID = next
                        focusedID = nil
                    }
                }
            } catch {}
        }
    }

    /// General > Customise Tab Bar on Apple TV.
    struct TabBarEditorPage: View {
        @State private var preferences = UICustomizationPreferences.shared
        @AppStorage private var swapsUtilities: Bool
        @AppStorage private var showsCalendar: Bool
        @Environment(\.dismiss) private var dismiss

        init() {
            _swapsUtilities = AppStorage(wrappedValue: false, MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities"))
            _showsCalendar = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab"))
        }

        /// Home and the saved tab that places Library, in bar order.
        private var visibleItems: [PrimaryMenuItem] {
            TVSettingsView.tabBarItems(preferences.resolvedPrimaryMenuItems())
        }

        private var canEdit: Bool {
            tvCustomizationMutationIsEnabled(allowsEditing: preferences.allowsEditing,
                                             usesDeviceMenuOverride: preferences.primaryMenuUsesDeviceOverride,
                                             changesFamilyMenu: true)
        }

        var body: some View {
            EditorPage {
                TVSettingsPageHeader(title: "Tab Bar", subtitle: "Choose and arrange your navigation tabs.")
                    .icon(.symbol("rectangle.3.group"))
                preview
                searchAndProfile
                visibleSection
                calendarSection
                TVSettingsFooter("Changes save automatically. Home and Library stay visible; press Back to return.")
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
            var tabs = visible.map {
                TabBarPreview.Tab(id: $0.id, title: TVSettingsView.tabBarTitle($0), symbol: TVSettingsView.tabBarSymbol($0))
            }
            if showsCalendar, let library = visible.firstIndex(where: { !$0.isHome }) {
                let calendar = TabBarPreview.Tab(id: "vivid.calendar", title: AppTab.calendar.title,
                                                 symbol: AppTab.calendar.icon)
                tabs.insert(calendar, at: library + 1)
            }
            return TabBarPreview(tabs: tabs, swapsUtilities: swapsUtilities)
        }

        // MARK: Groups

        // Each heading, group and footer below flattens into the page's
        // own stack, so every heading sits a full page gap above its group.

        private var searchAndProfile: some View {
            Group {
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
            return Group {
                heading("VISIBLE DESTINATIONS")
                TVSettingsGroup {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        let title = TVSettingsView.tabBarTitle(item)
                        HStack(spacing: TVSettingsLayout.scaled(12)) {
                            TVSettingsRowLabel(title: Text(title),
                                               detail: Text("Shown in the tab bar. Use the arrows to change its position."))
                            Spacer(minLength: TVSettingsLayout.scaled(12))
                            EditorSymbolButton(systemName: "arrow.up", label: Text("Move \(title) earlier")) {
                                setLibraryLeads(item.isHome ? false : true)
                            }
                            .disabled(index == 0)
                            EditorSymbolButton(systemName: "arrow.down", label: Text("Move \(title) later")) {
                                setLibraryLeads(item.isHome ? true : false)
                            }
                            .disabled(index == visible.count - 1)
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

        private var calendarSection: some View {
            let detail: LocalizedStringResource = !showsCalendar ? "Hidden from the tab bar."
                : "Shown in the tab bar, just after Library."
            return Group {
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

        /// Puts Home after or before every other saved tab. Movies, Series
        /// and For You, which Library stands for here, keep their own order
        /// for the clients that still show them.
        private func setLibraryLeads(_ leads: Bool) {
            let saved = preferences.resolvedPrimaryMenuItems()
            let home = saved.filter(\.isHome)
            let others = saved.filter { !$0.isHome }
            let menu = leads ? others + home : home + others
            guard menu != saved else { return }
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
                .icon(.symbol("rectangle.3.group"))
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
