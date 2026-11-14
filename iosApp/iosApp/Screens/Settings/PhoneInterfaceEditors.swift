#if os(iOS)
import SwiftUI

extension SettingsView {
    /// Settings > General > Customise Tab Bar.
    struct TabBarEditor: View {
        @State private var preferences = UICustomizationPreferences.shared
        @State private var previewSelection: String?
        @AppStorage private var swapsUtilities: Bool
        @AppStorage private var showsDownloads: Bool
        @AppStorage private var showsCalendar: Bool
        @Environment(\.scenePhase) private var scenePhase

        init() {
            _swapsUtilities = AppStorage(wrappedValue: false, MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities"))
            _showsDownloads = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showDownloadsTab"))
            _showsCalendar = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab"))
        }

        /// Home and the saved tab that places Library, in bar order. The
        /// saved Movies, Series and For You tabs stay in the menu.
        private var visibleItems: [PrimaryMenuItem] {
            let saved = preferences.resolvedPrimaryMenuItems()
            let anchor = tvTabBarLibraryAnchor(in: saved)
            return saved.filter { $0.isHome || $0 == anchor }
        }

        private var previewItems: [MobileGlassNavigationBar.Item] {
            var destinations = libraryMainTabDestinations(menuItems: preferences.resolvedPrimaryMenuItems())
            if showsCalendar { destinations.append(.app(.calendar)) }
            if showsDownloads { destinations.append(.app(.downloads)) }
            return destinations.map {
                MobileGlassNavigationBar.Item(id: String(describing: $0.id), title: $0.title,
                                              icon: $0.icon, selectedIcon: $0.selectedIcon)
            }
        }

        var body: some View {
            List {
                SettingsPageHeader(title: "Customise Tab Bar", subtitle: "Reorder tabs. Changes save automatically.",
                                   systemImage: "rectangle.3.group")
                    .settingsPageHeaderRow()
                previewSection
                Section {
                    tabSwitch(isOn: $showsDownloads, title: "Downloads", systemImage: "arrow.down.circle",
                              label: showsDownloads ? Text("Hide Downloads tab") : Text("Show Downloads tab"))
                    tabSwitch(isOn: $showsCalendar, title: "Calendar", systemImage: "calendar",
                              label: showsCalendar ? Text("Hide Calendar tab") : Text("Show Calendar tab"))
                } header: {
                    PhoneSettingsSectionHeader("Downloads")
                } footer: {
                    Text("Calendar sits just before Downloads in the tab bar.")
                }
                if let message = preferences.capabilityMessage {
                    Section {
                        Label(message, systemImage: "server.rack")
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                }
                if preferences.hasDeviceOverrides {
                    Section {
                        Label("This device has older device-specific interface settings that override family sync.",
                              systemImage: "iphone.and.arrow.forward")
                        Button(useSyncedTitle) { preferences.useFamilySettings() }
                            .disabled(preferences.isSaving || !preferences.allowsEditing)
                    } footer: {
                        Text("Clearing the device override makes the controls below apply to all like-family devices on this profile.")
                    }
                }
                menuSection
                if let error = preferences.syncErrorMessage, error != preferences.capabilityMessage {
                    Section {
                        Label(error, systemImage: "icloud.slash")
                            .font(.footnote)
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                }
            }
            .vividGroupedListStyle()
            .settingsListChrome()
            .navigationTitle("")
            .task { await preferences.refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await preferences.refresh() }
            }
        }

        private var previewSection: some View {
            Section {
                let items = previewItems
                MobileGlassNavigationBar(items: items, selectedID: previewSelection ?? items.first?.id,
                                         onSelect: { previewSelection = $0 })
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { swapsUtilities.toggle() } label: {
                    Label("Swap Search and Profile", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color(white: 0.26))
                .accessibilityValue(swapsUtilities ? Text("Profile on the left, Search on the right")
                                                   : Text("Search on the left, Profile on the right"))
                .accessibilityHint("Swaps the Search and Profile buttons at the ends of the tab bar")
            } header: {
                PhoneSettingsSectionHeader("Tab Bar Preview")
            } footer: {
                Text("Search and Profile stay separate from your tabs and can only swap places.")
            }
        }

        private func tabSwitch(isOn: Binding<Bool>, title: LocalizedStringKey, systemImage: String, label: Text) -> some View {
            Button { isOn.wrappedValue.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: isOn.wrappedValue ? "eye.fill" : "eye.slash.fill")
                        .frame(width: 32)
                    Label(title, systemImage: systemImage)
                    Spacer()
                }
                .frame(minHeight: 44)
                .foregroundStyle(.white)
            }
            .accessibilityLabel(label)
        }

        private var useSyncedTitle: LocalizedStringKey {
            switch AppleDeviceIdentity.current.clientFamily {
            case "mobile": "Use Synced Mobile Settings"
            case "tablet": "Use Synced Tablet Settings"
            case "desktop": "Use Synced Desktop Settings"
            default: "Use Synced Family Settings"
            }
        }

        private var menuSection: some View {
            let visible = visibleItems
            return Section {
                ForEach(visible) { item in
                    menuRow(item, in: visible)
                }
            } header: {
                PhoneSettingsSectionHeader("Primary Menu")
            } footer: {
                Text("Home and Library stay visible. Use the arrows to reorder them. Downloads (when available), Search, and Profile stay automatic.")
            }
            .disabled(!preferences.allowsEditing || preferences.primaryMenuUsesDeviceOverride)
        }

        private func menuRow(_ item: PrimaryMenuItem, in visible: [PrimaryMenuItem]) -> some View {
            let shown = shownTitleAndIcon(item)
            return HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: shown.icon).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.title).lineLimit(1)
                        Text(typeCaption(item).uppercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.vividSecondaryText.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !item.isHome {
                    HStack(spacing: 4) {
                        Button { move(item, by: -1, in: visible) } label: {
                            Image(systemName: "arrow.up")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(!canMove(item, by: -1, in: visible))
                        .accessibilityLabel("Move \(shown.title) up")
                        Button { move(item, by: 1, in: visible) } label: {
                            Image(systemName: "arrow.down")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(!canMove(item, by: 1, in: visible))
                        .accessibilityLabel("Move \(shown.title) down")
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }

        /// Home, or Library for the saved tab that places it.
        private func shownTitleAndIcon(_ item: PrimaryMenuItem) -> (title: String, icon: String) {
            if item.isHome { return (item.title, item.navigationIcon) }
            let library = MainTabDestination.library
            return (library.title, library.icon)
        }

        private func typeCaption(_ item: PrimaryMenuItem) -> String {
            item.isHome ? String(localized: "Your Stuff") : String(localized: "Media Type")
        }

        private func canMove(_ item: PrimaryMenuItem, by offset: Int, in visible: [PrimaryMenuItem]) -> Bool {
            guard let index = visible.firstIndex(of: item) else { return false }
            return !item.isHome && visible.indices.contains(index + offset)
        }

        private func move(_ item: PrimaryMenuItem, by offset: Int, in visible: [PrimaryMenuItem]) {
            guard canMove(item, by: offset, in: visible) else { return }
            // Home goes after or before every other saved tab, so Movies,
            // Series and For You keep their own order.
            let saved = preferences.resolvedPrimaryMenuItems()
            preferences.setPrimaryMenuItems(tabBarMenu(saved, libraryLeads: offset < 0))
        }
    }

    /// Settings > General > Home Sections: which Home rows show, and their
    /// order.
    struct HomeSectionsEditor: View {
        @State private var preferences = HomeSectionPreferences.shared
        @State private var sections: [ResolvedSection] = []
        @State private var isLoading = false
        @State private var failed = false

        private var rows: [ResolvedSection] { preferences.arrangedSections(sections, includingHidden: true) }

        var body: some View {
            List {
                SettingsPageHeader(title: "Home Sections",
                                   subtitle: "Choose up to 6 Home rows. A seventh slot is reserved for Spotlight, even when hidden.",
                                   systemImage: "rectangle.3.group")
                    .settingsPageHeaderRow()
                let arranged = rows
                if isLoading && arranged.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if arranged.isEmpty {
                    ContentUnavailableView {
                        Label("No Home Sections", systemImage: failed ? "wifi.exclamationmark" : "rectangle.3.group")
                    } description: {
                        Text(failed
                             ? "Vivid couldn’t refresh the Home rows. Try again when the server is reachable."
                             : "Home has no populated rows to arrange yet.")
                    }
                } else {
                    Section {
                        ForEach(arranged) { row($0) }
                            .onMove { from, to in
                                var ids = arranged.map(\.id)
                                ids.move(fromOffsets: from, toOffset: to)
                                preferences.setOrder(ids)
                            }
                    } footer: {
                        Text("\(preferences.visibleRowCount) of 6 rows enabled. Hide a row before showing another when all six are enabled. Open eye: shown on Home. Closed eye: hidden and dimmed here. Tap Edit to drag rows into a new order. Changes save automatically for this profile on this device.")
                    }
                }
            }
            .vividGroupedListStyle()
            .settingsListChrome()
            .navigationTitle("")
            .toolbar { EditButton() }
            .refreshable { await load() }
            .task { await load() }
        }

        private func row(_ section: ResolvedSection) -> some View {
            let visible = preferences.isVisible(section.id)
            return HStack(spacing: 12) {
                Button {
                    preferences.setVisible(!visible, sectionId: section.id)
                    if !visible { Task { await refreshFromServer() } }
                } label: {
                    Image(systemName: visible ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(visible ? Color.vividOnSurface : Color.vividSecondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!visible && preferences.visibleRowCount >= HomeSectionPreferences.maximumVisibleRows)
                .accessibilityLabel(visible ? Text("Hide \(section.title)") : Text("Show \(section.title)"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    if !section.items.isEmpty || section.totalCount != nil {
                        Text("\(section.items.count) items")
                            .font(.caption)
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                }
                Spacer(minLength: 8)
            }
            .opacity(visible ? 1 : 0.42)
            .animation(.easeInOut(duration: 0.12), value: visible)
        }

        private func load() async {
            preferences.refresh()
            if let cached = ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) {
                preferences.enforceVisibleRowLimit(in: cached.sections)
                sections = cached.sections
            }
            await refreshFromServer()
        }

        private func refreshFromServer() async {
            isLoading = sections.isEmpty
            failed = false
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
}
#endif
