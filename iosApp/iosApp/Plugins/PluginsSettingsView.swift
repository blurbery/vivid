import SwiftUI

struct PluginsSettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVSettingsGroup {
            NavigationLink { TVTMDbSettingsView() } label: {
                TVSettingsRowLabel(title: "Trailers", detail: "Trailers from your personal TMDB connection.")
            }.buttonStyle(TVSettingsPaneRowStyle())
            NavigationLink { OpenSubtitlesSettingsView() } label: {
                TVSettingsRowLabel(title: "OpenSubtitles", detail: "Find subtitles while watching.")
            }.buttonStyle(TVSettingsPaneRowStyle())
            NavigationLink { MDBListSettingsView() } label: {
                TVSettingsRowLabel(title: "MDBList", detail: "Sync watch history and watchlists.")
            }.buttonStyle(TVSettingsPaneRowStyle())
        }
        #else
        List {
            SettingsPageHeader(title: "Plugins", subtitle: "Trailers, subtitles, watch history and watchlists.", systemImage: "puzzlepiece.extension")
                .settingsPageHeaderRow()
            Section {
                NavigationLink("Trailers") { PhoneTMDbSettingsView() }
                NavigationLink("OpenSubtitles") { OpenSubtitlesSettingsView() }
                NavigationLink("MDBList") { MDBListSettingsView() }
            }
        }.settingsListChrome().navigationTitle("")
        #endif
    }
}

struct MDBListSettingsView: View {
    @State private var store = MDBListSyncStore.shared
    @State private var key = ""
    @State private var connecting = false
    @State private var message: String?

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                historyHeader
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: connectionStatus, showsConnectedDot: store.isConnected)
                    if store.isConnected && store.isSyncing { syncProgress.padding(24) }
                    if !store.isConnected {
                        TVSettingsFieldRow(title: "Personal API key", detail: "Get your free key at mdblist.com/preferences.") {
                            credentialField
                        }
                        Button { connect() } label: { TVSettingsRowLabel(title: connecting ? "Connecting…" : "Connect") }
                            .buttonStyle(TVSettingsPaneRowStyle()).disabled(connecting || key.isEmpty)
                    } else {
                        Button { store.importHistory() } label: { TVSettingsRowLabel(title: "Sync now") }
                            .buttonStyle(TVSettingsPaneRowStyle()).disabled(store.isSyncing)
                        Button { disconnect() } label: { TVSettingsRowLabel(title: "Disconnect") }
                            .buttonStyle(TVSettingsPaneRowStyle())
                    }
                }
                if store.isConnected { TVSettingsFooter(store.status) }
                if let message { TVSettingsFooter(message) }
                TVSettingsFooter(privacy)
            }.frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 48).frame(maxWidth: .infinity)
        }.background(SettingsBackdrop()).task { store.reload() }
        #else
        List {
            historyHeader
                .settingsPageHeaderRow()
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        if store.isConnected { Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true) }
                        Text(connectionStatus)
                    }
                }
                if store.isConnected && store.isSyncing { syncProgress.padding(.vertical, 6) }
                if !store.isConnected {
                    credentialField
                    Button(connecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(connecting || key.isEmpty)
                    Link("Get your free API key", destination: URL(string: "https://mdblist.com/preferences/")!)
                } else {
                    Button("Sync now") { store.importHistory() }.disabled(store.isSyncing)
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
                if store.isConnected { Text(store.status).font(.footnote).foregroundStyle(.secondary) }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text(privacy) }
        }.settingsListChrome().listSectionSpacing(8).navigationTitle("").task { store.reload() }
        #endif
    }

    @ViewBuilder
    private var syncProgress: some View {
        if let progress = store.syncProgress {
            VStack(alignment: .leading, spacing: 8) {
                Text(progress.description).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .accessibilityLabel(progress.description)
            }
        }
    }

    private var connectionStatus: String { connecting ? "Connecting…" : store.isConnected ? "Connected" : "Not connected" }

    private var credentialField: some View {
        SecureField("MDBList API key", text: $key)
            .autocorrectionDisabled()
            #if os(iOS) || os(tvOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(connecting)
    }

    private var historyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MDBList")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Bring your watch history to Vivid.")
                #if os(tvOS)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                #else
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                #endif
                .fixedSize(horizontal: false, vertical: true)
            Text("Import watched history and sync watchlists both ways with MDBList. Vivid also exports completed watches. Watchlist imports include titles on your active server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            integrationLogos
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            Label("Current watches and resume points stay untouched.", systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var integrationLogos: some View {
        let logos = [
            ("Kodi", "MDBListKodi"), ("Plex", "MDBListPlex"),
            ("Trakt", "MDBListTrakt"),
            ("Jellyfin", "MDBListJellyfin"), ("Emby", "MDBListEmby")
        ]
        #if os(tvOS)
        let size: CGFloat = 48
        let spacing: CGFloat = 16
        #else
        let size: CGFloat = 32
        let spacing: CGFloat = 8
        #endif
        return HStack(spacing: spacing) {
            ForEach(logos, id: \.0) { name, asset in
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.1)))
                    .accessibilityLabel(name)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Apps available through MDBList: Kodi, Plex, Trakt, Jellyfin and Emby")
    }

    private var privacy: String { "Your key is stored in Keychain and syncs through Vivid’s encrypted iCloud account vault. Sync shares media identifiers, watched dates and watchlist changes, never server login details. Disconnecting keeps existing history and watchlists." }

    private func connect() {
        let candidate = key
        connecting = true
        message = nil
        Task { @MainActor in
            defer { connecting = false }
            do {
                try await store.connect(candidate)
                key = ""
                await store.sync(force: true)
            } catch { message = error.localizedDescription }
        }
    }

    private func disconnect() {
        do { try store.disconnect(); key = ""; message = nil }
        catch { message = error.localizedDescription }
    }
}
