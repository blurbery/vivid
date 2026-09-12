#if !os(tvOS)
import SwiftUI

struct PrimaryMenuEditorRow: Identifiable, Equatable {
    let item: PrimaryMenuItem
    var id: String { item.id }
}

func offsetPrimaryMenuEditorItem(
    _ rows: [PrimaryMenuEditorRow], itemId: String, by offset: Int
) -> [PrimaryMenuItem]? {
    guard offset != 0,
          let source = rows.firstIndex(where: { $0.id == itemId }),
          !rows[source].item.isHome else { return nil }
    let target = source + offset
    guard rows.indices.contains(target), !rows[target].item.isHome else { return nil }
    var items = rows.map(\.item)
    items.swapAt(source, target)
    return items
}

/// Family-synced navigation and card presets for iPhone, iPad, and Mac.
/// Downloads, Search, and Profile are automatic shell utilities and stay
/// outside the reorderable list, matching the cross-client contract.
struct InterfaceCustomizationView: View {
    var menuOnly = false
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.showDownloadsTab")) private var showDownloadsTab = true
    @State private var previewSelection: String?
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var utilitiesSwapped = false
    @State private var preferences = UICustomizationPreferences.shared
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            SettingsPageHeader(title: menuOnly ? "Customise Tab Bar" : "Interface", subtitle: "Reorder or hide tabs. Changes save automatically.", systemImage: "rectangle.3.group").settingsPageHeaderRow()
            Section {
                #if os(iOS)
                MobileGlassNavigationBar(
                    items: previewItems,
                    selectedID: previewSelection ?? previewItems.first?.id,
                    onSelect: { previewSelection = $0 }
                )
                #endif
                Button { utilitiesSwapped.toggle() } label: {
                    Label("Swap Search and Profile", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color(white: 0.26))
                .accessibilityValue(utilitiesSwapped ? "Profile on the left, Search on the right" : "Search on the left, Profile on the right")
                .accessibilityHint("Swaps the Search and Profile buttons at the ends of the tab bar")
            } header: { PhoneSettingsSectionHeader("Tab Bar Preview") }
            footer: { Text("Search and Profile stay separate from your tabs and can only swap places.") }
            #if os(iOS)
            Section {
                Button { showDownloadsTab.toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: showDownloadsTab ? "eye.fill" : "eye.slash.fill").frame(width: 32)
                        Label("Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                    }.frame(minHeight: 44).foregroundStyle(.white)
                }.accessibilityLabel(showDownloadsTab ? "Hide Downloads tab" : "Show Downloads tab")
            } header: { PhoneSettingsSectionHeader("Downloads") }
            #endif
            if let message = preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "server.rack")
                        .foregroundStyle(Color.vividSecondaryText)
                }
            }

            if preferences.hasDeviceOverrides {
                Section {
                    Label(
                        "This device has older device-specific interface settings that override family sync.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    Button("Use Synced \(familySettingsName) Settings") {
                        preferences.useFamilySettings()
                    }
                    .disabled(preferences.isSaving || !preferences.allowsEditing)
                } footer: {
                    Text("Clearing the device override makes the controls below apply to all like-family devices on this profile.")
                }
            }

            if !menuOnly {
            Section {
                Picker("Preset", selection: presetSelection) {
                    ForEach(CardPresentationPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                    if preferences.cardPresentation.preset == nil {
                        Text("Custom").tag(Self.customPresetId)
                    }
                }

                Picker("Poster Size", selection: posterSize) {
                    ForEach(CardPosterSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }

                Picker("Captions", selection: captionStyle) {
                    ForEach(CardCaptionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                if preferences.cardPresentationUsesFamilyOverride {
                    Button("Use Profile Default") {
                        preferences.resetCardPresentationToInherited()
                    }
                    .disabled(preferences.isSaving)
                }
            } header: {
                PhoneSettingsSectionHeader("Poster Configuration")
            } footer: {
                Text("Start with Balanced, Compact, Cinema, or Artwork Only, then fine-tune size and captions. These choices sync with other \(familyLabel) devices on this profile.")
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            Section {
                NavigationLink {
                    HomeSectionsCustomizationView()
                } label: {
                    Label("Home Sections", systemImage: "rectangle.3.group")
                }
            } header: {
                PhoneSettingsSectionHeader("Home")
            } footer: {
                Text("Choose which Home rows are visible and the order they appear in.")
            }

            }
            Section {
                ForEach(visibleRows) { row in
                    let item = row.item
                    HStack(spacing: 12) {
                        menuLabel(for: item)
                        Spacer(minLength: 8)
                        if !item.isHome {
                            HStack(spacing: 4) {
                                Button {
                                    move(item, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canMove(item, by: -1))
                                .accessibilityLabel("Move \(displayTitle(for: item)) up")

                                Button {
                                    move(item, by: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canMove(item, by: 1))
                                .accessibilityLabel("Move \(displayTitle(for: item)) down")

                                Button {
                                    remove(item)
                                } label: {
                                    Image(systemName: "eye.fill")
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(removalVerb(for: item)) \(displayTitle(for: item))"
                                )
                            }
                            // The controls never compress; the flexible title
                            // column absorbs narrow widths by truncating.
                            .fixedSize()
                        }
                    }
                }
            } header: {
                PhoneSettingsSectionHeader("Primary Menu")
            } footer: {
                if isDefaultMenuApplied {
                    Text("Default menu applied. Reorder or hide tabs to customise.")
                } else {
                    Text("Home is required. Use the arrows to reorder tabs. Downloads (when available), Search, and Profile stay automatic.")
                }
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.primaryMenuUsesDeviceOverride
            )

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.vividSecondaryText)
                }
            }
        }
        .vividGroupedListStyle()
        .settingsListChrome()
        .navigationTitle("")
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

    #if os(iOS)
    private var previewItems: [MobileGlassNavigationBar.Item] {
        var destinations = projectedMainTabDestinations(
            primaryMenu: preferences.primaryMenu,
            availableLibraries: libraries
        )
        if showDownloadsTab { destinations.append(.app(.downloads)) }
        return destinations.map { .init(id: String(describing: $0.id), title: $0.title, icon: $0.icon, selectedIcon: $0.selectedIcon) }
    }
    #endif

    private var posterSize: Binding<CardPosterSize> {
        Binding(
            get: { preferences.cardPresentation.posterSize },
            set: { preferences.setPosterSize($0) }
        )
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { preferences.cardPresentation.preset?.rawValue ?? Self.customPresetId },
            set: { rawValue in
                guard let preset = CardPresentationPreset(rawValue: rawValue) else { return }
                preferences.setCardPresentation(preset.presentation)
            }
        )
    }

    private var captionStyle: Binding<CardCaptionStyle> {
        Binding(
            get: { preferences.cardPresentation.caption },
            set: { preferences.setCaptionStyle($0) }
        )
    }

    private static let customPresetId = "custom"

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

    private var visibleDestinations: [PrimaryMenuItem] {
        preferences.resolvedPrimaryMenuItems().filter {
            mainTabSupportsDestination($0, availableLibraries: libraries)
        }
    }

    private var visibleRows: [PrimaryMenuEditorRow] {
        visibleDestinations.map { PrimaryMenuEditorRow(item: $0) }
    }

    private var isDefaultMenuApplied: Bool {
        visibleDestinations.count == 1 && visibleDestinations[0].isHome
    }

    private func displayTitle(for item: PrimaryMenuItem) -> String {
        if case .library(let libraryId, _) = item,
           let currentName = libraries.first(where: { $0.id == libraryId })?.name {
            return currentName
        }
        return item.title
    }

    private func menuTypeTitle(_ item: PrimaryMenuItem) -> String {
        switch item {
        case .builtin(.movies), .builtin(.series): return "Media Type"
        case .builtin(.home): return "Your Stuff"
        case .builtin(.forYou): return "Discover"
        case .library, .section, .collection: return ""
        }
    }

    private func menuLabel(
        for item: PrimaryMenuItem
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: navigationIcon(for: item))
                .frame(width: 22)
            // The type caption sits under the title rather than beside it so
            // narrow screens never squeeze either into per-character wraps;
            // the title truncates instead of wrapping.
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(for: item))
                    .lineLimit(1)
                Text(
                    menuTypeTitle(item).uppercased()
                )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.vividSecondaryText.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    private func navigationIcon(for item: PrimaryMenuItem) -> String {
        guard case .library(let libraryId, _) = item else {
            return item.navigationIcon
        }
        return libraries.first(where: { $0.id == libraryId })?.navigationIcon
            ?? item.navigationIcon
    }

    private func move(_ item: PrimaryMenuItem, by offset: Int) {
        guard let items = offsetPrimaryMenuEditorItem(
            visibleRows,
            itemId: item.id,
            by: offset
        ) else { return }
        persistVisibleDestinations(items)
    }

    private func canMove(_ item: PrimaryMenuItem, by offset: Int) -> Bool {
        offsetPrimaryMenuEditorItem(
            visibleRows,
            itemId: item.id,
            by: offset
        ) != nil
    }

    private func remove(_ item: PrimaryMenuItem) {
        guard !item.isHome else { return }
        preferences.setPrimaryMenuItems(visibleDestinations.filter { $0.id != item.id })
    }

    private func removalVerb(for item: PrimaryMenuItem) -> String {
        return "Hide"
    }

    private func persistVisibleDestinations(_ destinations: [PrimaryMenuItem]) {
        preferences.setPrimaryMenuItems(destinations)
    }

    private func librarySort(_ lhs: Library, _ rhs: Library) -> Bool {
        (lhs.sortOrder ?? Int.max, lhs.id) < (rhs.sortOrder ?? Int.max, rhs.id)
    }

    private var familyLabel: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "iPhone-like"
        case "tablet": return "tablet-like"
        case "desktop": return "desktop-like"
        default: return "similar"
        }
    }

    private var familySettingsName: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "Mobile"
        case "tablet": return "Tablet"
        case "desktop": return "Desktop"
        default: return "Family"
        }
    }
}

/// Local profile-aware editor for the rows returned by `/home/sections`.
/// Visibility is an explicit eye control; native List editing supplies familiar
/// drag handles for ordering. Every change persists immediately, so returning
/// to Home reflects it without a separate network save or page reload.
struct HomeSectionsCustomizationView: View {
    @State private var preferences = HomeSectionPreferences.shared
    @State private var sections: [ResolvedSection] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        List {
            SettingsPageHeader(title: "Home Sections", subtitle: "Choose which rows appear on Home and arrange their order.", systemImage: "rectangle.3.group").settingsPageHeaderRow()
            Section {
                if arrangedSections.isEmpty, isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if arrangedSections.isEmpty {
                    ContentUnavailableView(
                        "No Home Sections",
                        systemImage: loadFailed ? "wifi.exclamationmark" : "rectangle.3.group",
                        description: Text(
                            loadFailed
                                ? "Vivid couldn’t refresh the Home rows. Try again when the server is reachable."
                                : "Home has no populated rows to arrange yet."
                        )
                    )
                } else {
                    ForEach(arrangedSections) { section in
                        sectionRow(section)
                    }
                    .onMove(perform: moveSections)
                }
            } footer: {
                if !arrangedSections.isEmpty {
                    Text("Open eye: shown on Home. Closed eye: hidden and dimmed here. Tap Edit to drag rows into a new order. Changes save automatically for this profile on this device.")
                }
            }
        }
        .vividGroupedListStyle()
        .settingsListChrome()
        .navigationTitle("")
        #if os(iOS)
        .toolbar {
            EditButton()
        }
        #endif
        .task {
            await loadSections()
        }
        .refreshable {
            await loadSections(forceRefresh: true)
        }
    }

    private var arrangedSections: [ResolvedSection] {
        preferences.arrangedSections(sections, includingHidden: true)
    }

    private func sectionRow(_ section: ResolvedSection) -> some View {
        let isVisible = preferences.isVisible(section.id)
        return HStack(spacing: 12) {
            Button {
                preferences.setVisible(!isVisible, sectionId: section.id)
                if !isVisible { Task { await refreshFromServer() } }
            } label: {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isVisible ? Color.vividOnSurface : Color.vividSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isVisible ? "Hide \(section.title)" : "Show \(section.title)"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(1)

                if !section.items.isEmpty || section.totalCount != nil {
                    Text("\(section.items.count) item\(section.items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.vividSecondaryText)
                }
            }

            Spacer(minLength: 8)
        }
        .opacity(isVisible ? 1 : 0.42)
        .animation(.easeInOut(duration: VividTheme.fastDuration), value: isVisible)
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        var ids = arrangedSections.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        preferences.setOrder(ids)
    }

    private func loadSections(forceRefresh: Bool = false) async {
        preferences.refresh()

        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            sections = cached.sections.filter { !$0.items.isEmpty || !HomeSectionPreferences.shared.isVisible($0.id) }
        }

        _ = forceRefresh
        // Cached rows paint immediately; this awaited refresh remains owned by
        // the view task so it is cancelled cleanly when the editor disappears.
        await refreshFromServer()
    }

    private func refreshFromServer() async {
        isLoading = sections.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard !Task.isCancelled else { return }
            sections = response.sections.filter { !$0.items.isEmpty || !HomeSectionPreferences.shared.isVisible($0.id) }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = sections.isEmpty
        }
    }
}
#endif
