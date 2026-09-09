#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var homeCards = TVHomeCardPreferences.shared
    var body: some View {
        List {
            SettingsPageHeader(title: "General", subtitle: "App-level options for this device.", systemImage: "gearshape").settingsPageHeaderRow()
            Section {
                #if os(iOS)
                NavigationLink { PhoneSpotlightSettingsView() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home Screen")
                        Text("Choose up to three rows for your discovery spotlight.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                #endif
                NavigationLink { HomeSectionsCustomizationView() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Home Sections")
                        Text("Choose which rows appear on Home and arrange their order.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { PhoneTMDbSettingsView() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trailers")
                        Text("Configure your personal TMDB API to show trailers for your media.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { PhoneSettingsSectionHeader("Home Screen") }
            Section {
                Picker("Poster Size", selection: Binding(get: { homeCards.presentation.posterSize }, set: { homeCards.setPosterSize($0) })) {
                    ForEach(CardPosterSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Captions", selection: Binding(get: { homeCards.presentation.caption }, set: { homeCards.setCaptionStyle($0) })) {
                    ForEach(CardCaptionStyle.allCases) { Text($0.title).tag($0) }
                }
                Button("Use Profile Default") { homeCards.reset() }.foregroundStyle(.white)
            } header: { PhoneSettingsSectionHeader("Poster Configuration") } footer: {
                Text("Captions apply across Home, Search, Movies, Series and For You. Title & Year, Title Only and Artwork Only keep the same text size and left alignment. Episodes show episode details instead of the year.")
            }
            Section {
                NavigationLink("Customise Tab Bar") { InterfaceCustomizationView(menuOnly: true) }
            } header: { PhoneSettingsSectionHeader("Tab Bar") }
            #if os(iOS)
            Section {
                NavigationLink("Downloads") { DownloadsSettingsView() }
            } header: { PhoneSettingsSectionHeader("Downloads") }
            #endif
            VividCopyrightFooter().frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .settingsListChrome()
        .navigationTitle("")
        .vividNavigationTitleDisplayMode(.inline)
    }
}

struct PhoneTMDbSettingsView: View {
    @State private var store = TVTMDbStore.shared
    @State private var credential = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            SettingsPageHeader(title: "Trailers", subtitle: "Configure your personal TMDB API to show trailers for your media.", systemImage: "film.stack")
                .settingsPageHeaderRow()
            Section {
                LabeledContent("Status", value: busy ? "Connecting…" : store.isConfigured ? "Connected" : "Not configured")
                SecureField("API key or read access token", text: $credential)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Save Connection") {
                    let input = credential
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            try await store.connect(input)
                            credential = ""
                            message = "Connected"
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(busy || credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.isConfigured {
                    Button("Disconnect", role: .destructive) {
                        do { try store.disconnect(); message = nil }
                        catch { message = error.localizedDescription }
                    }.disabled(busy)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { PhoneSettingsSectionHeader("TMDB Connection") }
            Section {
                Image("TMDbAttributionLogo").resizable().scaledToFit().frame(width: 100)
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("TMDB", destination: URL(string: "https://www.themoviedb.org")!)
            }
        }
        .settingsListChrome()
        .navigationTitle("")
    }
}
#if os(iOS)
struct PhoneSeerrSettingsView: View {
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
                    Image("SeerrSettingsIcon").renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                        .padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    Text("Seerr").font(.system(size: 30, weight: .bold, design: .rounded))
                }
            }.listRowBackground(Color.clear)
            Section {
                LabeledContent("Status", value: busy ? "Connecting…" : store.isConfigured ? "Connected" : "Not configured")
                TextField("Server URL", text: $url).keyboardType(.URL)
                TextField("Username or email", text: $username)
                SecureField("Password", text: $password)
                Button("Save Connection") {
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            try await store.connect(url: url, username: username, password: password)
                            password = ""; message = "Connected"
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(busy)
                if store.isConfigured {
                    Button("Disconnect", role: .destructive) {
                        do { try store.disconnect(); password = ""; message = nil }
                        catch { message = error.localizedDescription }
                    }.disabled(busy)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { PhoneSettingsSectionHeader("Connection") }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .settingsListChrome().navigationTitle("")
        .onAppear { url = store.configuration?.url ?? ""; username = store.configuration?.username ?? "" }
    }
}
#endif
#if os(iOS)
struct PhoneSpotlightSettingsView: View {
    @State private var preferences = TVHomeSpotlightPreferences.shared
    @State private var sections: [ResolvedSection] = []
    var body: some View {
        List {
            SettingsPageHeader(title: "Home Screen", subtitle: "Choose up to three rows for your discovery spotlight.", systemImage: "rectangle.3.group").settingsPageHeaderRow()
            Section {
                ForEach(sections) { section in
                    Button { preferences.toggle(section.id) } label: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            if preferences.selectedRowIDs?.contains(section.id) == true { Image(systemName: "checkmark") }
                        }
                    }
                }
            } header: { PhoneSettingsSectionHeader("Discovery Spotlight") } footer: { Text("Choose up to three Home sections for Discovery Spotlight.") }
        }.navigationTitle("").settingsListChrome()
        .onAppear {
            TVHomeMetadataCache.shared.hydrate()
            if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
                sections = cached.sections.filter { !$0.items.isEmpty }
                preferences.initializeIfNeeded(from: sections)
            }
        }
        .task {
            do {
                let response = try await StartupContentPrefetcher.fetchHomeSections()
                guard !Task.isCancelled else { return }
                sections = response.sections.filter { !$0.items.isEmpty }
                preferences.initializeIfNeeded(from: sections)
            } catch { /* Keep cached choices available when the server is slow or unavailable. */ }
        }
    }
}
struct PhoneHomeMetadataSettingsView: View {
    @State private var cache = TVHomeMetadataCache.shared
    var body: some View {
        List {
            SettingsPageHeader(title: "Metadata", subtitle: "Manage Home content saved on this device.", systemImage: "internaldrive").settingsPageHeaderRow()
            Section {
                ForEach(cache.statuses) { row in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title)
                            Text(row.updatedAt == nil ? "Not cached" : "\(row.count) items saved")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let date = row.updatedAt {
                                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { cache.clear(row.id) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.borderless).accessibilityLabel("Clear \(row.title) cache")
                    }
                }
            } header: { PhoneSettingsSectionHeader("Home Screen") }
            footer: {
                Text("Spotlight and your enabled Home rows are saved on this device for the current server and profile. Each row keeps up to 20 items; Spotlight keeps up to 10 slides. New Home data replaces stale items automatically. Clearing a section removes its saved metadata and unused artwork; it caches again when Home refreshes.")
            }
            if let error = cache.storageError { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("").settingsListChrome()
        .onAppear { cache.activate(); cache.reconcilePreferences() }
    }
}
#endif
#endif
