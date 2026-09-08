#if os(iOS)
import SwiftUI

struct IOSSettingsOverview: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Make Vivid work the way you like.").foregroundStyle(.secondary)
                PhoneSavedAccountCards(isSettings: true)
                VStack(spacing: 0) {
                    destination("General", "App and navigation", "gearshape") { GeneralSettingsView() }
                    SettingsOverviewDivider()
                    destination("Playback", "Quality and episodes", "play.rectangle") { PlaybackSettingsView(viewModel: viewModel) }
                    SettingsOverviewDivider()
                    destination("Subtitles", "Language and appearance", "captions.bubble") { SubtitleSettingsView(viewModel: viewModel) }
                    SettingsOverviewDivider()
                    destination("Servers", "Connection and version", "server.rack") {
                        PhoneServerSettingsView(viewModel: viewModel, showSignOutConfirm: $showSignOutConfirm)
                    }
                    SettingsOverviewDivider()
                    destination("Seerr", "Media requests", "SeerrSettingsIcon") { PhoneSeerrSettingsView() }
                    SettingsOverviewDivider()
                    destination("Metadata", "Home cache and storage", "internaldrive") { PhoneHomeMetadataSettingsView() }
                    SettingsOverviewDivider()
                    destination("About", "App details and contact", "AboutInfoIcon") { AboutSettingsView() }
                }
                .background(Color.vividSurfaceElevated.opacity(0.84), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                VividCopyrightFooter().frame(maxWidth: .infinity).padding(.top, 16)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("")
        .settingsNavigationChrome()
    }

    private func destination<Content: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(destination: content()) {
            SettingsOverviewRow(title: title, subtitle: subtitle, systemImage: icon, tint: .white)
        }.buttonStyle(.plain)
    }
}

struct PhoneServerSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router
    var body: some View {
        List {
            SettingsPageHeader(title: "Servers", subtitle: "The media server this device is connected to.", systemImage: "server.rack").settingsPageHeaderRow()
            Section {
                LabeledContent("Server", value: viewModel.serverDisplayName)
                LabeledContent("Address", value: viewModel.serverUrl)
                NavigationLink("Manage Servers") { ServerListView() }.foregroundStyle(.white)
            } header: { PhoneSettingsSectionHeader("Connection") }
        }.settingsListChrome().navigationTitle("")
    }
}
#endif

#if os(iOS)
struct PhoneVividPrivacyView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Vivid Privacy Policy").font(.system(size: 30, weight: .bold, design: .rounded))
                policySection("Your accounts and media server", "Vivid connects to the media servers you choose. Your server receives the sign-in details and requests needed to provide your account, library, artwork and playback. The server operator controls that information and may keep its own logs and records. Vivid’s policy does not replace your server operator’s privacy policy.")
                policySection("Information on this device", "Vivid saves account names, selected viewing profiles and preferences on the device. Saved account session tokens and optional account PIN records use Keychain. The saved-account feature does not retain the password you enter. Home metadata, artwork and playback buffers may be cached locally so the app can load and play media efficiently.")
                policySection("Playback and connected features", "Vivid sends playback position, pause state and watched-progress updates to the selected server. Subtitles and chapters are read from the opened media on this device; Vivid does not request external subtitle files or subtitle translation. If you configure TMDb trailers, your personal API credential is stored in Keychain and sent to TMDb with media identifiers. Opening a trailer connects to YouTube. These services receive normal connection information and apply their own privacy policies.")
                policySection("Optional IntroDB lookup", "With IntroDB enabled in Playback settings, Vivid sends the series IMDb ID, season and episode number directly to api.introdb.app to retrieve intro and credits timestamps. IntroDB also receives normal connection information such as your IP address. Vivid does not send your media-server credentials. IntroDB is enabled by default, can be turned off in Playback settings, and does not require an API key.")
                policySection("Optional Seerr connection", "If you configure Seerr, Vivid stores its URL, username and password in Keychain on this device to restore your connection. Seerr receives your login, search queries and media requests. Disconnect in Settings → Seerr to remove the saved connection. Your Seerr operator controls records kept on that server.")
                policySection("Diagnostics", "Vivid does not capture or upload in-app diagnostics reports. Technical logs used for development and troubleshooting stay local.")
                policySection("Your controls", "You can clear Home metadata and unused artwork from Settings → Metadata. Manual Sign Out clears the current saved-account session while keeping its profile card for later sign-in. Removing local data does not delete media, account records or watch history held by your server. Contact the server operator about information stored there.")
                policySection("Contact and changes", "For questions about Vivid, contact admin@vividapp.co. Vivid is in development; this information will be updated as its features and data handling change.")
            }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(Color.black.ignoresSafeArea()).navigationTitle("")
            .settingsNavigationChrome()
    }
    private func policySection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}
#endif

#if os(iOS)
struct PhoneSavedProfilesScreen: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                VividLogoView(size: 140)
                Text("Who’s watching?").font(.system(size: 30, weight: .bold, design: .rounded))
                PhoneSavedAccountCards(isSettings: false)
                Spacer()
                VividCopyrightFooter().padding(.bottom, 24)
            }.background(Color.black.ignoresSafeArea())
        }
    }
}

struct PhoneSavedAccountCards: View {
    let isSettings: Bool
    @State private var store = TVSavedAccountStore.shared
    @Environment(AppRouter.self) private var router
    @State private var selectedForPIN: TVSavedAccount?
    @State private var pin = ""
    @State private var pinError: String?
    var body: some View {
        GeometryReader { geometry in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 22) {
                ForEach(store.accounts) { account in
                    if store.needsLogin(account) || (isSettings && account.id == store.activeID) {
                        NavigationLink { PhoneSavedAccountEditor(accountID: account.id) } label: { tile(account) }
                            .contextMenu {
                                if account.requiresLogin {
                                    Button("Delete Profile", role: .destructive) {
                                        Task { await store.deleteSignedOutAccount(account.id, router: router) }
                                    }
                                }
                            }
                    } else {
                        Button {
                            if store.hasPIN(account.id) { selectedForPIN = account; pin = ""; pinError = nil }
                            else { Task { await store.select(account, router: router) } }
                        } label: { tile(account) }
                    }
                }
                if store.canAddAccount {
                NavigationLink { PhoneSavedAccountEditor(accountID: nil) } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 32))
                            .frame(width: 88, height: 88).background(.white.opacity(0.12), in: Circle())
                        Text("Add Profile").font(.subheadline.weight(.medium))
                    }.frame(width: 112)
                }
                }
            }.padding(.vertical, 12)
                .frame(minWidth: geometry.size.width, alignment: isSettings ? .leading : .center)
        }
        }.frame(height: 150).buttonStyle(.plain).foregroundStyle(.white).disabled(store.busy)
        .task { await store.captureCurrent() }
        .alert("Profile", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: $selectedForPIN) { account in
            NavigationStack {
                Form {
                    SecureField("PIN", text: $pin).keyboardType(.numberPad)
                    if let pinError { Text(pinError).foregroundStyle(.red) }
                    Button("Unlock") {
                        if store.unlock(account.id, pin: pin) {
                            selectedForPIN = nil; pin = ""
                            Task { await store.select(account, router: router) }
                        } else { pinError = store.error ?? "Incorrect PIN"; pin = "" }
                    }
                }.navigationTitle(account.username)
                .toolbar { Button("Cancel") { selectedForPIN = nil; pin = "" } }
            }.presentationDetents([.medium])
        }
    }
    private func isCurrentAccount(_ account: TVSavedAccount) -> Bool {
        account.id == store.activeID && !account.requiresLogin && AuthService.shared.isLoggedIn
            && account.serverID == ServerRegistry.shared.activeServerId
    }
    private func savedAvatarURL(_ account: TVSavedAccount) -> String? {
        guard let raw = account.profile?.avatarImageUrl else { return nil }
        if raw.hasPrefix("/"), let server = ServerRegistry.shared.entry(with: account.serverID) {
            return server.url + raw
        }
        return raw
    }
    private func tile(_ account: TVSavedAccount) -> some View {
        VStack(spacing: 12) {
            ProfileAvatarView(avatar: account.profile?.avatarEmoji, imageUrl: savedAvatarURL(account), name: account.username, size: 88)
                .overlay {
                    Circle().strokeBorder(isSettings && isCurrentAccount(account) ? Color.white : .clear, lineWidth: 3)
                }
                .accessibilityLabel(isSettings && isCurrentAccount(account) ? "Current account" : account.username)
            Text(account.username).font(.subheadline.weight(.medium)).lineLimit(1)
            if store.needsLogin(account) { Text("Signed out").font(.caption).foregroundStyle(.secondary) }
        }.frame(width: 112)
    }
}

struct PhoneSavedAccountEditor: View {
    let accountID: String?
    @State private var store = TVSavedAccountStore.shared
    @State private var registry = ServerRegistry.shared
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var provider = "Silo"
    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var message: String?
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var account: TVSavedAccount? { store.accounts.first { $0.id == accountID } }
    private var active: Bool { accountID != nil && accountID == store.activeID && !store.showsSelector && AuthService.shared.isLoggedIn }
    var body: some View {
        List {
            SettingsPageHeader(title: account?.username ?? "Add Profile", subtitle: "Account details and access on this device.", systemImage: "person.crop.circle").settingsPageHeaderRow()
            if account == nil {
                Section {
                    Picker("Server Provider", selection: $provider) {
                        Text("Silo").tag("Silo")
                        Text("Emby").tag("Emby")
                        Text("Jellyfin · Coming soon").tag("Jellyfin")
                    }
                    if !registry.entries.isEmpty {
                        Picker("Saved Server", selection: $serverURL) {
                            Text("Enter an address").tag("")
                            ForEach(registry.entries) { Text($0.displayName).tag($0.url) }
                        }
                    }
                } header: { PhoneSettingsSectionHeader("Server") }
            }
            Section {
                if account == nil { TextField("Server address", text: $serverURL).keyboardType(.URL) }
                else { LabeledContent("Server", value: registry.entry(with: account!.serverID)?.displayName ?? serverURL) }
                TextField("Username", text: $username).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
                Button(account == nil ? "Add Profile" : store.needsLogin(account!) ? "Sign In" : "Update Login") {
                    Task {
                        let success = await store.authenticate(id: accountID, serverURL: serverURL, username: username, password: password, router: router, provider: provider == "Emby" ? .emby : .silo)
                        password = ""
                        if success { dismiss() } else { message = store.error }
                    }
                }.disabled((accountID == nil && !store.canAddAccount) || provider == "Jellyfin" || store.busy || (password.isEmpty && provider != "Emby") || username.isEmpty || serverURL.isEmpty)
            } header: { PhoneSettingsSectionHeader("Account") }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            if active, let accountID {
                Section {
                    SecureField("New PIN", text: $pin).keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $confirmPIN).keyboardType(.numberPad)
                    Button(store.hasPIN(accountID) ? "Change PIN" : "Set PIN") {
                        guard pin == confirmPIN else { message = "The PINs don’t match."; return }
                        if store.setPIN(pin, accountID: accountID) { message = "PIN saved"; pin = ""; confirmPIN = "" }
                        else { message = store.error }
                    }.disabled(store.busy)
                    if store.hasPIN(accountID) {
                        Button("Remove PIN") { message = store.removePIN(accountID) ? "PIN removed" : "Couldn’t remove the PIN." }
                    }
                } header: { PhoneSettingsSectionHeader("PIN Protection") }
                Section {
                    Button("Sign Out", role: .destructive) { Task { await store.signOut(router: router) } }
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            VividCopyrightFooter().frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }.settingsListChrome().navigationTitle("")
        .onAppear {
            if let account {
                provider = MediaServerProvider.forServerID(account.serverID) == .emby ? "Emby" : "Silo"
                username = account.username
                serverURL = registry.entry(with: account.serverID)?.url ?? ""
            } else { serverURL = registry.activeServer?.url ?? "" }
        }
    }
}
#endif
