#if os(iOS)
import SwiftUI

struct IOSSettingsOverview: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router
    @State private var profileEditorRoute: PhoneProfileEditorRoute?

    var body: some View {
        List {
            SettingsPageHeader(title: "Settings", subtitle: "Make Vivid work the way you like.", systemImage: "gearshape")
                .settingsPageHeaderRow()
            Section {
                PhoneSavedAccountCards(isSettings: true, editorRoute: $profileEditorRoute)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
                    destination("General", "App and navigation", "gearshape") { GeneralSettingsView() }
                    destination("Playback", "Quality and episodes", "play.rectangle") { PlaybackSettingsView(viewModel: viewModel) }
                    destination("Subtitles", "Language and appearance", "captions.bubble") { SubtitleSettingsView(viewModel: viewModel) }
                    destination("Servers", "Connection and version", "server.rack") {
                        PhoneServerSettingsView(viewModel: viewModel, showSignOutConfirm: $showSignOutConfirm)
                    }
                    destination("Plugins", "Trailers and watched history", "puzzlepiece.extension") { PluginsSettingsView() }
                    destination("Seerr", "Media requests", "SeerrSettingsIcon") { PhoneSeerrSettingsView() }
                    destination("Metadata", "Home cache and storage", "internaldrive") { PhoneHomeMetadataSettingsView() }
                    destination("About", "App details and contact", "AboutInfoIcon") { AboutSettingsView() }
            } header: {
                PhoneSettingsSectionHeader("Profiles & Settings")
            }
            VividCopyrightFooter().frame(maxWidth: .infinity)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .settingsListChrome()
        .navigationTitle("")
        .navigationDestination(item: $profileEditorRoute) { route in
            PhoneSavedAccountEditor(accountID: route.accountID)
        }
    }

    private func destination<Content: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(destination: content()) {
            SettingsOverviewRow(title: title, subtitle: subtitle, systemImage: icon, tint: .white, showsChevron: false)
        }.buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 16))
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
                policySection("Information on this device", "Vivid saves preferences, downloads, Home metadata, artwork and playback buffers on the device. Saved account session tokens and optional Vivid PIN records use Keychain. The saved-account feature does not retain the media-server password you enter.")
                policySection("Private iCloud account sync", "When iCloud is available, Vivid stores saved server addresses, account and viewing-profile details, login sessions, optional Vivid PIN records and profile order in encrypted fields in your private iCloud database. Shared browsing, navigation, metadata and download preferences, plus configured Trailers, MDBList, OpenSubtitles and Seerr connection details, also sync between your iPhone, iPad and Apple TV for the matching server account and viewing profile. Playback and subtitle preferences, downloaded media, artwork and metadata caches stay on the device. Playback history and resume positions stay with your media server. Optional MDBList imports add local watched indicators, described below.")
                policySection("Playback and connected features", "Vivid sends playback position, pause state and watched-progress updates to the selected server. Subtitles and chapters are read from the opened media on this device. If you connect OpenSubtitles in Plugins, searches send the title, language, media type, season number and episode number to OpenSubtitles. Chosen subtitle files are downloaded temporarily to this device. A small, limited memory cache reuses recent downloads during the app session and clears when the connection changes. Your API key stays in Keychain, separate for each server account and profile, and syncs through the encrypted private iCloud account vault. Searches send the key only to the OpenSubtitles API. Subtitles are not uploaded to your media server. Subtitle translation is not provided. If you configure TMDb trailers, your personal API credential is stored in Keychain and sent to TMDb with media identifiers for trailers and missing Emby metadata IDs. Opening a trailer connects to YouTube. These services receive normal connection information and apply their own privacy policies.")
                policySection("Optional skip timestamp lookups", "With Intro & Credit Skipper enabled in Playback settings, Vivid can send the series IMDb ID, season and episode number to api.introdb.app and api.theintrodb.org to fill missing intro, recap and credits timestamps. These services also receive normal connection information such as your IP address. Vivid does not send your media-server credentials. The skipper is enabled by default, can be turned off in Playback settings, and does not require an API key.")
                policySection("Optional MDBList connection", "If you connect MDBList in Settings → Plugins, Vivid keeps your personal API key in this device’s Keychain. It reads watched history and sends completed movie and episode identifiers and watched dates to MDBList. Movie and series watchlist additions and removals also sync in both directions for matching titles on the active media server. Media-server credentials are never sent to MDBList. The connection syncs through the encrypted private iCloud account vault for the same server account and viewing profile. Imported watched indicators and sync checkpoints remain on each device, including after a connection failure. Reconnecting the same MDBList account reuses saved progress while checking for remote changes. Imports skip already-watched items, active watches and rewatches, and unknown or non-zero resume positions. They never overwrite server watch history or resume positions. Disconnecting stops syncing without deleting watched history or watchlists.")
                policySection("Optional Seerr connection", "If you configure Seerr, Vivid stores its URL, username and password in Keychain on this device to restore your connection. Seerr receives your login, search queries and media requests. Disconnect in Settings → Seerr to remove the saved connection. Your Seerr operator controls records kept on that server.")
                policySection("Diagnostics", "Vivid does not capture or upload in-app diagnostics reports. Technical logs used for development and troubleshooting stay local. Apple’s TestFlight service separately collects beta usage, crash information and submitted feedback under its own privacy terms.")
                policySection("Your controls", "You can clear Home metadata and unused artwork from Settings → Metadata. Manual Sign Out clears the current saved-account session while keeping its profile card for later sign-in, and that signed-out state syncs through iCloud. Deleting a saved account records the deletion in the private vault so another device cannot add it back; signing in again later can restore it. Removing Vivid clears data stored by that installation but does not delete the private iCloud vault, data on another device or records held by your media server. Contact the server operator about information stored there.")
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
    @State private var profileEditorRoute: PhoneProfileEditorRoute?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                VividLogoView(size: 140)
                Text("Who’s watching?").font(.system(size: 30, weight: .bold, design: .rounded))
                PhoneSavedAccountCards(isSettings: false, editorRoute: $profileEditorRoute)
                Spacer()
                VividCopyrightFooter().padding(.bottom, 24)
            }.background(Color.black.ignoresSafeArea())
                .navigationDestination(item: $profileEditorRoute) { route in
                    PhoneSavedAccountEditor(accountID: route.accountID)
                }
        }
    }
}

struct PhoneSavedAccountCards: View {
    let isSettings: Bool
    @State private var store = TVSavedAccountStore.shared
    @State private var registry = ServerRegistry.shared
    @Environment(AppRouter.self) private var router
    @State private var selectedForPIN: TVSavedAccount?
    @Binding var editorRoute: PhoneProfileEditorRoute?
    @GestureState private var reorderGestureActive = false
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dragStartFrame: CGRect = .zero
    @State private var draftOrder: [String] = []
    @State private var hoveredSlot: CGRect?
    @State private var dragOffset: CGSize = .zero
    @State private var movingID: String?
    @State private var lastDragEndedAt: ContinuousClock.Instant?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pin = ""
    @State private var pinError: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isSettings {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 112), spacing: 12, alignment: .top)], alignment: .leading, spacing: 16) {
                    profileCards
                }
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            profileCards
                        }
                        .padding(.vertical, 12)
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                }
                .frame(height: 150)
            }
        }
        .coordinateSpace(name: "savedProfileCards")
        .onPreferenceChange(ProfileCardFrames.self) { cardFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let movingID, let account = store.accounts.first(where: { $0.id == movingID }) {
                tile(account)
                    .frame(width: dragStartFrame.width, height: dragStartFrame.height)
                    .scaleEffect(reduceMotion ? 1 : 1.04)
                    .position(x: dragStartFrame.midX + dragOffset.width,
                              y: dragStartFrame.midY + dragOffset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: reorderGestureActive) { _, active in
            if !active { resetDrag() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetDrag() }
        }
        .onDisappear { resetDrag() }
        .buttonStyle(.plain).foregroundStyle(.white).disabled(store.busy)
        .task { await store.captureCurrent() }
        .task(id: scenePhase == .active && movingID == nil) {
            guard scenePhase == .active, movingID == nil else { return }
            while !Task.isCancelled {
                await VividCloudAccountSync.shared.synchronize(router: router)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
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
    private var avatarSize: CGFloat { isSettings ? 72 : 88 }

    @ViewBuilder
    private var profileCards: some View {
        ForEach(displayedAccounts) { account in
            Button { activateProfile(account) } label: {
                tile(account)
            }
            .buttonStyle(.plain)
            .opacity(movingID == account.id ? 0 : 1)
            .contentShape(Rectangle())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ProfileCardFrames.self,
                        value: [account.id: geometry.frame(in: .named("savedProfileCards"))])
                }
            }
            .simultaneousGesture(reorderGesture(for: account))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Hold and drag onto another profile to reorder. Release to save.")
            .accessibilityAction(named: "Move earlier") { moveProfile(account.id, by: -1) }
            .accessibilityAction(named: "Move later") { moveProfile(account.id, by: 1) }
        }
        if store.canAddAccount {
            Button { editorRoute = .add } label: {
                VStack(spacing: isSettings ? 8 : 12) {
                    Image(systemName: "plus").font(.system(size: 32))
                        .frame(width: avatarSize, height: avatarSize).background(.white.opacity(0.12), in: Circle())
                    Text("Add Profile").font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                }.frame(width: isSettings ? nil : 112)
                    .frame(maxWidth: isSettings ? .infinity : nil)
            }
        }
    }

    private func serverLabel(for account: TVSavedAccount) -> String {
        if MediaServerProvider.forServerID(account.serverID) == .emby { return "Emby" }
        return registry.entry(with: account.serverID)?.displayName ?? "Media server"
    }

    private func activateProfile(_ account: TVSavedAccount) {
        guard movingID == nil, !store.busy else { return }
        // A drag release can also finish the button's press. Ignore that release,
        // while keeping ordinary profile taps on the native button path.
        if let lastDragEndedAt, lastDragEndedAt.duration(to: .now) < .milliseconds(200) { return }
        if store.needsLogin(account) || (isSettings && account.id == store.activeID) {
            editorRoute = .account(account.id)
        } else if store.hasPIN(account.id) {
            selectedForPIN = account
            pin = ""
            pinError = nil
        } else {
            Task { await store.select(account, router: router) }
        }
    }

    private func reorderGesture(for account: TVSavedAccount) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("savedProfileCards")))
            .updating($reorderGestureActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard !store.busy, store.accounts.count > 1,
                      case .second(true, let drag) = value else { return }
                if movingID == nil {
                    dragStartFrame = cardFrames[account.id] ?? .zero
                    draftOrder = store.accounts.map(\.id)
                    movingID = account.id
                }
                guard movingID == account.id, let drag else { return }
                dragOffset = drag.translation
                previewReorder(at: drag.location, moving: account.id)
            }
            .onEnded { value in
                defer { resetDrag() }
                guard movingID == account.id,
                      case .second(true, let drag?) = value,
                      cardFrames.values.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(drag.location) }) else { return }
                _ = store.saveAccountOrder(draftOrder)
            }
    }

    private var displayedAccounts: [TVSavedAccount] {
        guard movingID != nil else { return store.accounts }
        let ids = VividCloudPreferencePolicy.ordered(store.accounts.map(\.id), preferred: draftOrder)
        let byID = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private func previewReorder(at point: CGPoint, moving id: String) {
        if let hoveredSlot, hoveredSlot.contains(point) { return }
        hoveredSlot = nil
        guard let target = displayedAccounts.first(where: {
            $0.id != id && cardFrames[$0.id]?.insetBy(dx: -6, dy: -6).contains(point) == true
        }), let frame = cardFrames[target.id],
              let from = draftOrder.firstIndex(of: id),
              let to = draftOrder.firstIndex(of: target.id) else { return }
        hoveredSlot = frame.insetBy(dx: -6, dy: -6)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            draftOrder.remove(at: from)
            draftOrder.insert(id, at: to)
        }
    }

    private func resetDrag() {
        if movingID != nil { lastDragEndedAt = .now }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            movingID = nil
            draftOrder = []
        }
        dragOffset = .zero
        dragStartFrame = .zero
        hoveredSlot = nil
    }

    private func moveProfile(_ id: String, by offset: Int) {
        let current = store.accounts.map(\.id)
        let order = VividCloudPreferencePolicy.moving(current, id: id, by: offset)
        guard current != order else { return }
        _ = store.saveAccountOrder(order)
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
        VStack(spacing: isSettings ? 8 : 12) {
            ProfileAvatarView(avatar: account.profile?.avatarEmoji, imageUrl: savedAvatarURL(account), name: account.username, size: avatarSize)
                .overlay {
                    Circle().strokeBorder(isSettings && isCurrentAccount(account) ? Color.white : .clear, lineWidth: 3)
                }
                .accessibilityLabel(isSettings && isCurrentAccount(account) ? "Current account" : account.username)
            VStack(spacing: 4) {
                Text(account.username).font(.subheadline.weight(.medium)).lineLimit(1)
                if isSettings {
                    Text(serverLabel(for: account))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if store.needsLogin(account) { Text("Signed out").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(width: isSettings ? nil : 112)
            .frame(maxWidth: isSettings ? .infinity : nil)
    }
}

enum PhoneProfileEditorRoute: Hashable {
    case add
    case account(String)

    var accountID: String? {
        switch self {
        case .add: nil
        case .account(let id): id
        }
    }
}

private struct ProfileCardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
    @State private var showsDeleteConfirm = false
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
                    Button(role: .destructive) {
                        Task { await store.signOut(router: router) }
                    } label: {
                        Text("Sign Out")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            if account != nil {
                Section {
                    Button("Delete Profile", role: .destructive) { showsDeleteConfirm = true }
                        .disabled(store.busy)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            VividCopyrightFooter().frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }.settingsListChrome().navigationTitle("")
        .confirmationDialog("Delete Profile?", isPresented: $showsDeleteConfirm,
                            titleVisibility: .visible, presenting: account) { account in
            Button("Delete Profile", role: .destructive) {
                Task {
                    if await store.deleteAccount(account.id, router: router) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Remove \(account.username) and its saved connection from Vivid on your iCloud devices? Other profiles and the actual server account and library won’t be deleted.")
        }
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
