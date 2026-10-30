#if os(iOS)
import SwiftUI

extension SettingsView {
    /// Settings > General: language, theme, Home, posters, tab bar and
    /// downloads.
    struct GeneralPage: View {
        @State private var language = VividAppLanguage.saved
        @State private var reopenLanguage: VividAppLanguage?
        @State private var showsReopen = false
        @AppStorage(VividAppTheme.storageKey) private var theme: VividAppTheme = .graphite
        @State private var sections = HomeSectionPreferences.shared
        @State private var studios = StudiosNetworksStore.shared
        @State private var collections = HomeCollectionsStore.shared
        @State private var tmdb = TVTMDbStore.shared
        @State private var cards = TVHomeCardPreferences.shared
        @State private var registry = ServerRegistry.shared

        private var provider: MediaServerProvider { MediaServerProvider.forServerID(registry.activeServerId) }

        var body: some View {
            List {
                SettingsPageHeader(title: "General", subtitle: "App-level options for this device.", systemImage: "gearshape")
                    .settingsPageHeaderRow()
                Section {
                    Picker("Language", selection: languageSelection) {
                        Text("System").tag(VividAppLanguage.system)
                        ForEach(VividAppLanguage.allCases.filter { $0 != .system }) {
                            Text(verbatim: $0.nativeName ?? "").tag($0)
                        }
                    }
                } header: {
                    PhoneSettingsSectionHeader("Language")
                } footer: {
                    Text("System follows this device’s language. A new choice takes effect after you close Vivid in the app switcher and open it again.")
                }
                Section {
                    Picker("Theme", selection: $theme) {
                        ForEach(VividAppTheme.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                } header: {
                    PhoneSettingsSectionHeader("Themes")
                } footer: {
                    Text("Graphite uses the charcoal background, Black uses solid black, and Native removes Vivid’s background and uses the system appearance.")
                }
                homeScreenSection
                Section {
                    Picker("Captions", selection: Binding(get: { cards.presentation.caption },
                                                          set: { cards.setCaptionStyle($0) })) {
                        ForEach(CardCaptionStyle.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    Button("Use Profile Default") { cards.reset() }
                        .foregroundStyle(.white)
                } header: {
                    PhoneSettingsSectionHeader("Poster Configuration")
                } footer: {
                    Text("Captions apply across Home, Search, Movies, Series and For You. Title & Year, Title Only and Artwork Only keep the same text size and left alignment. Episodes show episode details instead of the year.")
                }
                Section {
                    NavigationLink("Customise Tab Bar") { TabBarEditor() }
                } header: { PhoneSettingsSectionHeader("Tab Bar") }
                Section {
                    NavigationLink("Downloads") { DownloadsSettingsView() }
                } header: { PhoneSettingsSectionHeader("Downloads") }
                VividCopyrightFooter()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .settingsListChrome()
            .navigationTitle("")
            .onAppear(perform: refreshStores)
            .onChange(of: registry.activeServerId) { refreshStores() }
            .alert("Reopen Vivid", isPresented: $showsReopen, presenting: reopenLanguage) { _ in
                Button("OK", role: .cancel) {}
            } message: { language in
                if language == .system {
                    Text("Vivid will use this device’s language the next time it opens. Close Vivid in the app switcher, then open it again.")
                } else {
                    Text("Vivid will use \(language.nativeName ?? "") the next time it opens. Close Vivid in the app switcher, then open it again.")
                }
            }
        }

        private var homeScreenSection: some View {
            Section {
                NavigationLink { SpotlightPage() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home Screen")
                        Text("Choose up to three rows for your discovery spotlight.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink { PhoneStudiosNetworksSettingsView() } label: {
                    LabeledContent("Studios & Networks") {
                        Text(!tmdb.isConfigured ? "Needs sign-in" : studios.isEnabled ? "On" : "Off")
                    }
                }
                NavigationLink { HomeSectionsEditor() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home Sections")
                        Text("Choose which rows appear on Home and arrange their order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink { PhoneHomeCollectionsSettingsView() } label: {
                    LabeledContent("Collections") {
                        Text(collections.isEnabled ? "On" : "Off")
                    }
                }
                if provider == .emby {
                    Toggle("Combine Next Up with Continue Watching",
                           isOn: Binding(get: { sections.combineEmbyNextUp }, set: { sections.setCombineEmbyNextUp($0) }))
                } else if provider == .jellyfin {
                    Toggle("Combine Next Up with Continue Watching",
                           isOn: Binding(get: { sections.combineJellyfinNextUp }, set: { sections.setCombineJellyfinNextUp($0) }))
                }
            } header: { PhoneSettingsSectionHeader("Home Screen") }
        }

        private var languageSelection: Binding<VividAppLanguage> {
            Binding(get: { language }, set: { choice in
                language = choice
                VividAppLanguage.save(choice)
                if VividAppLanguage.needsReopen(for: choice) {
                    reopenLanguage = choice
                    showsReopen = true
                } else {
                    showsReopen = false
                }
            })
        }

        private func refreshStores() {
            sections.refresh()
            collections.refresh()
        }
    }

    /// Settings > Seerr: the request server connection.
    struct SeerrPage: View {
        @State private var store = TVSeerrConnectionStore.shared
        @State private var url = ""
        @State private var username = ""
        @State private var password = ""
        @State private var busy = false
        @State private var message: String?

        var body: some View {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("SeerrSettingsIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .padding(10)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        Text(verbatim: "Seerr")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                }
                .listRowBackground(Color.clear)
                Section {
                    LabeledContent("Status") {
                        Text(busy ? "Connecting…" : store.isConfigured ? "Connected" : "Not configured")
                    }
                    TextField("Server URL", text: $url)
                        .keyboardType(.URL)
                    TextField("Username or email", text: $username)
                    SecureField("Password", text: $password)
                    Button("Save Connection", action: save)
                        .disabled(busy)
                    if store.isConfigured {
                        Button("Disconnect", role: .destructive, action: disconnect)
                            .disabled(busy)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { PhoneSettingsSectionHeader("Connection") }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .settingsListChrome()
            .navigationTitle("")
            .onAppear {
                if let configuration = store.configuration {
                    url = configuration.url
                    username = configuration.username
                }
            }
        }

        private func save() {
            busy = true
            Task {
                do {
                    try await store.connect(url: url, username: username, password: password)
                    password = ""
                    message = String(localized: "Connected")
                } catch {
                    message = error.localizedDescription
                }
                busy = false
            }
        }

        private func disconnect() {
            do {
                try store.disconnect()
                password = ""
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Settings > General > Home Screen: which Home rows feed the discovery
    /// spotlight.
    struct SpotlightPage: View {
        @State private var spotlight = TVHomeSpotlightPreferences.shared
        @State private var sections: [ResolvedSection] = []

        var body: some View {
            List {
                SettingsPageHeader(title: "Home Screen", subtitle: "Choose up to three rows for your discovery spotlight.",
                                   systemImage: "rectangle.3.group")
                    .settingsPageHeaderRow()
                Section {
                    ForEach(spotlight.sourceSections(from: sections)) { section in
                        Button { spotlight.toggle(section.id) } label: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                if spotlight.selectedRowIDs?.contains(section.id) == true {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    PhoneSettingsSectionHeader("Discovery Spotlight")
                } footer: {
                    Text("Choose up to three Home sections for Discovery Spotlight.")
                }
            }
            .settingsListChrome()
            .navigationTitle("")
            .onAppear {
                TVHomeMetadataCache.shared.hydrate()
                if let cached = ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) {
                    show(cached.sections)
                }
            }
            .task {
                guard let response = try? await StartupContentPrefetcher.fetchHomeSections(), !Task.isCancelled else { return }
                show(response.sections)
            }
        }

        private func show(_ rows: [ResolvedSection]) {
            sections = rows.filter { !$0.items.isEmpty }
            spotlight.initializeIfNeeded(from: sections)
        }
    }

    /// Settings > Metadata: the Home content saved on this device.
    struct MetadataPage: View {
        @State private var cache = TVHomeMetadataCache.shared

        var body: some View {
            List {
                SettingsPageHeader(title: "Metadata", subtitle: "Manage Home content saved on this device.", systemImage: "internaldrive")
                    .settingsPageHeaderRow()
                Section {
                    ForEach(cache.statuses) { status in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(status.title)
                                Text(status.updatedAt == nil ? "Not cached" : "\(status.count) items saved")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let date = status.updatedAt {
                                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { cache.clear(status.id) } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear \(status.title) cache")
                        }
                    }
                } header: {
                    PhoneSettingsSectionHeader("Home Screen")
                } footer: {
                    Text("Spotlight and your enabled Home rows are saved on this device for the current server and profile. Each row keeps up to 20 items; Spotlight keeps up to 10 slides. New Home data replaces stale items automatically. Clearing a section removes its saved metadata and unused artwork; it caches again when Home refreshes.")
                }
                if let error = cache.storageError {
                    Text(error).foregroundStyle(.secondary)
                }
            }
            .settingsListChrome()
            .navigationTitle("")
            .onAppear {
                cache.activate()
                cache.reconcilePreferences()
            }
        }
    }
}

/// Settings > Plugins > TMDb.
struct PhoneTMDbSettingsView: View {
    @State private var store = TVTMDbStore.shared

    var body: some View {
        List {
            SettingsPageHeader(title: "TMDb",
                               subtitle: "Trailers, TMDB ratings, collections, Studios & Networks, the Calendar's Trending and any air dates TVmaze doesn't have come from TMDB through Vivid. There's nothing to set up.",
                               systemImage: "film.stack")
                .settingsPageHeaderRow()
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        if store.isConfigured {
                            Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        }
                        Text(store.isConfigured ? "Connected" : "Not available")
                    }
                }
            } header: { PhoneSettingsSectionHeader("TMDB Connection") }
            Section {
                Image("TMDbAttributionLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100)
                // TMDB's required notice stays in English.
                Text(verbatim: "This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("TMDB", destination: URL(string: "https://www.themoviedb.org")!)
            }
        }
        .settingsListChrome()
        .navigationTitle("")
    }
}
#endif
