#if os(iOS)
import SwiftUI

extension SettingsView {
    /// Settings > General > Customise Tab Bar.
    struct TabBarEditor: View {
        @State private var preferences = UICustomizationPreferences.shared
        @State private var snapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
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

        private var authority: MainTabLibraryAuthority? {
            MainTabLibraryAuthority(serverId: ServerRegistry.shared.activeServerId,
                                    profileId: ServerRegistry.shared.activeProfileId)
        }

        private var libraries: [Library] { snapshot.availableLibraries(for: authority) }

        private var visibleItems: [PrimaryMenuItem] {
            preferences.resolvedPrimaryMenuItems().filter { mainTabSupportsDestination($0, availableLibraries: libraries) }
        }

        private var hiddenDefaults: [PrimaryMenuItem] {
            let visible = visibleItems
            return appleDefaultPrimaryMenuItems().filter {
                !visible.contains($0) && mainTabSupportsDestination($0, availableLibraries: libraries)
            }
        }

        private var usesDefaultMenu: Bool {
            guard let menu = preferences.primaryMenu else { return true }
            return menu.items == [.builtin(.home)]
        }

        private var previewItems: [MobileGlassNavigationBar.Item] {
            var destinations = projectedMainTabDestinations(primaryMenu: preferences.primaryMenu, availableLibraries: libraries)
            if showsCalendar { destinations.append(.app(.calendar)) }
            if showsDownloads { destinations.append(.app(.downloads)) }
            return destinations.map {
                MobileGlassNavigationBar.Item(id: String(describing: $0.id), title: $0.title,
                                              icon: $0.icon, selectedIcon: $0.selectedIcon)
            }
        }

        var body: some View {
            List {
                SettingsPageHeader(title: "Customise Tab Bar", subtitle: "Reorder or hide tabs. Changes save automatically.",
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
            .task(id: authority) { await refreshLibraries(for: authority) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let current = authority
                Task {
                    async let menu: Void = preferences.refresh()
                    async let shelves: Void = refreshLibraries(for: current)
                    _ = await (menu, shelves)
                }
            }
        }

        private var previewSection: some View {
            Section {
                let items = previewItems
                MobileGlassNavigationBar(items: items, selectedID: previewSelection ?? items.first?.id,
                                         onSelect: { previewSelection = $0 })
                    .frame(maxWidth: .infinity)
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
                ForEach(hiddenDefaults) { item in
                    Button { preferences.setPrimaryMenuItems(visible + [item]) } label: {
                        Label("Show \(item.title)", systemImage: "eye")
                    }
                }
            } header: {
                PhoneSettingsSectionHeader("Primary Menu")
            } footer: {
                Text(usesDefaultMenu
                     ? "Default menu applied. Reorder or hide tabs to customise."
                     : "Home is required. Use the arrows to reorder tabs. Downloads (when available), Search, and Profile stay automatic.")
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
                        Button { preferences.setPrimaryMenuItems(visible.filter { $0 != item }) } label: {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Hide \(shown.title)")
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }

        /// A library tab shows the library's current name and icon when
        /// it's known.
        private func shownTitleAndIcon(_ item: PrimaryMenuItem) -> (title: String, icon: String) {
            if case .library(let libraryId, _) = item, let library = libraries.first(where: { $0.id == libraryId }) {
                return (library.name, library.navigationIcon)
            }
            return (item.title, item.navigationIcon)
        }

        private func typeCaption(_ item: PrimaryMenuItem) -> String {
            switch item {
            case .builtin(.movies), .builtin(.series): String(localized: "Media Type")
            case .builtin(.home): String(localized: "Your Stuff")
            case .builtin(.forYou): String(localized: "Discover")
            default: ""
            }
        }

        private func canMove(_ item: PrimaryMenuItem, by offset: Int, in visible: [PrimaryMenuItem]) -> Bool {
            guard let index = visible.firstIndex(of: item), visible.indices.contains(index + offset) else { return false }
            return !item.isHome && !visible[index + offset].isHome
        }

        private func move(_ item: PrimaryMenuItem, by offset: Int, in visible: [PrimaryMenuItem]) {
            guard canMove(item, by: offset, in: visible), let index = visible.firstIndex(of: item) else { return }
            var items = visible
            items.swapAt(index, index + offset)
            preferences.setPrimaryMenuItems(items)
        }

        /// Keeps libraries only for the server and profile they belong to,
        /// then fetches that profile's libraries.
        private func refreshLibraries(for authority: MainTabLibraryAuthority?) async {
            if snapshot.authority != authority {
                snapshot = MainTabLibrarySnapshot(authority: authority, libraries: [])
            }
            guard let authority else { return }
            guard let response = try? await StartupContentPrefetcher.fetchUserLibraries(),
                  !Task.isCancelled, self.authority == authority else { return }
            snapshot = MainTabLibrarySnapshot(authority: authority, libraries: response.libraries)
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
