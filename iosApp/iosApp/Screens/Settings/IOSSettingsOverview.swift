#if os(iOS)
import SwiftUI

struct IOSSettingsOverview: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router
    @State private var profileEditorRoute: PhoneProfileEditorRoute?
    @State private var unsentDiagnostics = 0
    @Environment(\.duoSideStrip) private var duoSideStrip

    var body: some View {
        List {
            Text("Settings")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .settingsPageHeaderRow()

            if duoSideStrip == nil {
                Section {
                    profileCards
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                } header: {
                    PhoneSettingsSectionHeader("Profiles")
                }
            }

            Section {
                destination("General", "App and navigation", "gearshape") { GeneralSettingsView() }
                destination("Playback", "Quality, audio and episodes", "play.rectangle") { PlaybackSettingsView(viewModel: viewModel) }
                destination("Subtitles", "Language and appearance", "captions.bubble") { SubtitleSettingsView(viewModel: viewModel) }
                destination("Servers", "Connection and version", "server.rack") {
                    PhoneServerSettingsView(viewModel: viewModel, showSignOutConfirm: $showSignOutConfirm)
                }
                destination("Plugins", "Trailers and watched history", "puzzlepiece.extension") { PluginsSettingsView() }
                destination("Seerr", "Media requests", "SeerrSettingsIcon") { PhoneSeerrSettingsView() }
                destination("Metadata", "Home cache and storage", "internaldrive") { PhoneHomeMetadataSettingsView() }
                destination("Diagnostics", diagnosticsSubtitle, "stethoscope") { DiagnosticsSettingsView() }
                destination("About", "App details and contact", "AboutInfoIcon") { AboutSettingsView() }
            } header: {
                PhoneSettingsSectionHeader("Settings")
            }

            VividCopyrightFooter()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .settingsListChrome()
        .overlay {
            if let duoSideStrip {
                profileStrip(duoSideStrip)
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("")
        .navigationDestination(item: $profileEditorRoute) { route in
            PhoneSavedAccountEditor(accountID: route.accountID)
        }
        .task { await refreshDiagnosticsCount() }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            Task { await refreshDiagnosticsCount() }
        }
    }

    private var profileCards: some View {
        PhoneSavedAccountCards(isSettings: true, editorRoute: $profileEditorRoute)
    }

    /// Beside the iPhone Duo's side status bar the profiles stand in the
    /// strip as a bar of avatars, like the tab bar on other pages, under the
    /// X and on the status icons' line.
    private func profileStrip(_ strip: PhoneDuo.SideStrip) -> some View {
        PhoneSavedAccountCards(isSettings: true, editorRoute: $profileEditorRoute, isStrip: true)
            .frame(width: 2 * PhoneDuo.ControlCorner.centreFromEdge)
            .padding(.top, strip.controlsTop + 44 + 14)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: strip.edge == .trailing ? .topTrailing : .topLeading
            )
            .ignoresSafeArea()
    }

    private var diagnosticsSubtitle: LocalizedStringKey {
        unsentDiagnostics == 0 ? "Crash and hang reports" : "\(unsentDiagnostics) new"
    }

    private func refreshDiagnosticsCount() async {
        unsentDiagnostics = await Task.detached(priority: .utility) {
            AppHealthSendState.unsent(in: AppHealthStore.shared.reports()).count
        }.value
    }

    private func destination<Content: View>(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(destination: content()) {
            HStack(spacing: 14) {
                Group {
                    if icon == "SeerrSettingsIcon" || icon == "AboutInfoIcon" {
                        Image(icon).renderingMode(.template).resizable().scaledToFit().padding(9)
                    } else {
                        Image(systemName: icon).font(.body.weight(.medium))
                    }
                }
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)


            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
    }
}

struct PhoneServerSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var showSignOutConfirm: Bool
    @Environment(AppRouter.self) private var router
    @State private var store = TVSavedAccountStore.shared
    @State private var renaming = false
    @State private var serverName = ""
    @State private var renameError: String?
    var body: some View {
        List {
            SettingsPageHeader(title: "Servers", subtitle: "The media server this device is connected to.", systemImage: "server.rack").settingsPageHeaderRow()
            Section {
                Button(action: beginRename) {
                    LabeledContent("Server") {
                        HStack(spacing: 6) {
                            Text(store.activeAccount?.serverName ?? viewModel.serverDisplayName)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .foregroundStyle(.white)
                .disabled(store.activeAccount == nil)
                .accessibilityHint("Rename this server for this profile")
                LabeledContent("Address", value: viewModel.serverUrl)
                NavigationLink("Manage Servers") { ServerListView() }.foregroundStyle(.white)
            } header: { PhoneSettingsSectionHeader("Connection") } footer: {
                if let renameError {
                    Text(renameError)
                } else if store.activeAccount != nil {
                    Text("Tap Server to rename it for this profile.")
                }
            }
        }.settingsListChrome().navigationTitle("")
            .alert("Rename Server", isPresented: $renaming) {
                TextField(defaultLabel, text: $serverName)
                Button("Save") { rename(to: serverName) }
                if store.activeAccount?.serverName != nil {
                    Button("Use Server Name") { rename(to: nil) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name shows for this profile only, under its profile picture and here. Leave it blank to show “\(defaultLabel)”.")
            }
    }

    /// What a blank name shows under the profile, as the field's placeholder.
    private var defaultLabel: String { store.activeAccount?.defaultServerLabel ?? viewModel.serverDisplayName }

    private func beginRename() {
        renameError = nil
        // Starts empty without a name, with the label a blank name shows as
        // the placeholder, so saving untouched never pins a name to the profile.
        serverName = store.activeAccount?.serverName ?? ""
        renaming = true
    }

    private func rename(to name: String?) {
        guard let account = store.activeAccount, store.renameServer(for: account.id, to: name) else {
            renameError = String(localized: "Couldn’t rename the server. Try again.")
            return
        }
    }
}
#endif

#if os(iOS)
struct PhoneVividPrivacyView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Vivid Privacy Policy").font(.system(size: 30, weight: .bold, design: .rounded))
                policySection("Your accounts and media server", "Vivid connects to the media servers you choose. Your server receives the sign-in details and requests needed to provide your account, library, artwork and playback. Depending on the provider, requests also identify this device by its name, a generated client identifier, platform and app version/build. The server operator controls that information and may keep its own logs and records. Vivid’s policy does not replace your server operator’s privacy policy.")
                policySection("Optional Emby Connect sign-in", "If you choose Use Emby Connect when signing in to an Emby server, Vivid asks Emby’s Emby Connect service (connect.emby.media) for a PIN, sending a generated device identifier and the app name and version. You enter the PIN on emby.media with your Emby Connect email and password, which Vivid never receives. Vivid then receives an Emby Connect sign-in token and the list of servers linked to your Emby Connect account, uses them once to sign in to the server you chose, and doesn’t keep them. Emby Connect also receives normal connection information, including your IP address, and handles it under Emby’s own privacy policy. Signing in with a password doesn’t contact Emby Connect.")
                policySection("Information on this device", "Vivid saves preferences, downloads and their subtitle files, Home metadata, artwork and playback buffers on the device. Saved account session tokens and optional Vivid PIN records use Keychain. The saved-account feature does not retain the media-server password you enter.")
                policySection("Private iCloud account sync", "When iCloud is available, Vivid stores saved server addresses, account and viewing-profile details (including any server name you give a profile), login sessions, optional Vivid PIN records and profile order in encrypted fields in your private iCloud database. Shared browsing, navigation, metadata and download preferences, plus configured MDBList, OpenSubtitles and Seerr connection details, also sync between your iPhone, iPad and Apple TV for the matching server account and viewing profile. Playback and subtitle preferences, downloaded media, artwork and metadata caches stay on the device. Playback history and resume positions stay with your media server. Optional MDBList completed-watch exports and watchlist sync are described below.")
                policySection("Playback and connected features", "Vivid sends playback position, pause state and watched-progress updates to the selected server, and tells Emby and Jellyfin which audio and subtitle tracks are playing. Subtitles and chapters are read from the opened media on this device, along with subtitle files a Silo, Emby or Jellyfin server keeps beside it and subtitles a Silo server stores for it. If you connect OpenSubtitles in Plugins, searches send the title, language, media type, season number and episode number to OpenSubtitles. The subtitle file you choose is downloaded to this device and kept with that title, along with any subtitle delay you set for it, for your 40 most recent titles, so it comes back when you resume. Choosing another subtitle, Off or Auto, or disconnecting, removes it. A small, limited memory cache reuses recent downloads during the app session and clears when the connection changes. Your API key stays in Keychain, separate for each server account and profile, and syncs through the encrypted private iCloud account vault. Searches send the key only to the OpenSubtitles API. Subtitles are not uploaded to your media server. Subtitle translation is not provided. Vivid uses TMDb for trailers, ratings, movie collections and missing Emby and Jellyfin metadata IDs, and Studios & Networks asks it for studio and network logos and their most popular titles. These lookups go through Vivid’s TMDb relay (tmdb.vividapp.co, on Cloudflare), which sends them to TMDb with Vivid’s own key. The relay receives media identifiers and the lists requested, and uses your network address only to limit requests, without storing it or passing it to TMDb. Vivid doesn’t use a TMDb key of yours, and deletes one saved by an earlier version from your devices and the iCloud vault. Your library and watch history are matched on this device and are not sent to TMDb or the relay. When a page has trailers, Vivid loads their preview images from YouTube, and opening a trailer hands it to the YouTube app or website. Seerr request artwork loads from TMDb’s image service. These services receive normal connection information and apply their own privacy policies.")
                policySection("Skip timestamp lookups", "With Intro & Credit Skipper enabled in Playback settings, Vivid can look up missing intro, recap and credits timestamps. IntroDB (api.introdb.app) receives the series IMDb ID and season and episode numbers. TheIntroDB (api.theintrodb.org) receives the series TMDb ID when available, otherwise its IMDb ID, plus season and episode numbers. These services also receive normal connection information such as your IP address. Vivid does not send your media-server credentials. The skipper is enabled by default, can be turned off in Playback settings, and does not require an API key.")
                policySection("Calendar", "The Calendar finds new episodes of series in your Continue Watching, Watchlist and history. Vivid looks up their air times from TVmaze and their next air date from TMDb through Vivid’s relay (tmdb.vividapp.co, on Cloudflare), which receives only the TVDB, IMDb or TMDb IDs of those series and uses your network address only to limit requests, without storing it or passing it on. TVmaze never sees your address. Trending asks TMDb through the same relay for popular titles coming soon. Upcoming posters load from your server, and Trending posters load from TMDb’s image service, which receives normal connection information. Your library, watch history and account aren’t sent to TVmaze, TMDb or the relay. Vivid keeps the Calendar’s list of your series with their air dates, and Trending, on this device for each profile, so it doesn’t look them all up on every visit. Deleting the saved account removes them.")
                policySection("Optional MDBList connection", "If you connect MDBList in Settings → Plugins, Vivid keeps your personal API key in this device’s Keychain. It sends movie and episode identifiers and watched dates for new completions or titles you explicitly mark watched in Vivid, only after your media server confirms the watched update. Neither service’s existing watched history is scanned or imported, and MDBList does not replace server watched indicators or resume positions. Movie and series watchlist additions and removals sync in both directions for matching titles on the active media server. Media-server credentials are never sent to MDBList. The connection syncs through the encrypted private iCloud account vault for the same server account and viewing profile. Pending exports and confirmed sync checkpoints remain on each device across connection failures. Reconnecting the same MDBList account reuses those checkpoints; watchlist sync reads fresh remote lists. Old local watched-import records are discarded without changing either service’s history. Disconnecting stops syncing without deleting watched history or watchlists.")
                policySection("Optional Seerr connection", "If you configure Seerr, Vivid stores its URL, username and password in Keychain to restore your connection, and they sync through the encrypted private iCloud account vault for the matching server account and viewing profile. Seerr receives your login, search queries and media requests. Disconnect in Settings → Seerr to remove the saved connection. Your Seerr operator controls records kept on that server.")
                policySection("Diagnostics", "Vivid keeps reports of crashes, freezes, unexpected exits, playback failures, download failures and app errors on this device to help fix problems, including Apple’s MetricKit diagnostics. A report contains the app version, device model, system version, technical details such as call stacks, whether the app was launching, browsing or playing, and a short log of recent app events such as screens opened, playback steps and errors, with addresses, file names and identifiers removed. The reports Vivid writes contain no titles, account details or server addresses and are kept for up to 14 days. A download failure report also notes which step failed, the server type, the error code, the chosen quality and whether it was part of a season or series download. It also keeps a record of the latest playback only, replaced each time something new plays: the server type and play method, the audio output and display setup, the video and audio formats, and counts of dropped frames, buffering, audio faults and sync drift, time spent paused or waiting to load, Vivid’s memory use each minute, and on iPhone and iPad how often the player controls appeared and what made them go away soon after, with no titles, item IDs, account details or server addresses. Vivid never uploads them automatically. They leave the device only if you choose to send them from Settings → Diagnostics, where you can view exactly what is sent and delete them. Sending them delivers them to Vivid’s diagnostics service at diagnostics.vividapp.co, which runs on Cloudflare, emails them to diagnostics@vividapp.co through the Resend email service and keeps a copy on Cloudflare for 30 days. To have a report you’ve sent deleted, email admin@vividapp.co with the reference shown after sending it. If you add a note saying what happened, it’s sent with them as you wrote it, apart from removing spaces at the ends and control or text-direction characters, and keeping it to 500 characters. Vivid doesn’t check a note for personal details, so leave out passwords and server addresses. The device’s network address is used only to limit how often reports can be sent and isn’t stored. Other Options sends them with Mail or the share sheet instead. Detailed development logs are only written by development builds and stay on the device. Apple’s TestFlight service separately collects beta usage, crash information and submitted feedback under its own privacy terms.")
                policySection("Your controls", "You can clear Home metadata and unused artwork from Settings → Metadata, and delete diagnostics reports from Settings → Diagnostics. Manual Sign Out clears the current saved-account session while keeping its profile card for later sign-in, and that signed-out state syncs through iCloud. Deleting a saved account records the deletion in the private vault so another device cannot add it back; signing in again later can restore it. Removing Vivid clears data stored by that installation but does not delete the private iCloud vault, data on another device or records held by your media server. Contact the server operator about information stored there.")
                policySection("Contact and changes", "For questions about Vivid, contact admin@vividapp.co. Vivid is in development; this information will be updated as its features and data handling change.")
            }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.background(VividAppBackdrop()).navigationTitle("")
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
    @State private var store = TVSavedAccountStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.count > 4 {
                    // Five to eight profiles scroll on a screen too short
                    // for them all, and stay centred otherwise.
                    GeometryReader { container in
                        ScrollView {
                            content.frame(minHeight: container.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                } else {
                    content
                }
            }
            .background(VividAppBackdrop())
            .navigationDestination(item: $profileEditorRoute) { route in
                PhoneSavedAccountEditor(accountID: route.accountID)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            Spacer()
            VividLogoView(size: store.accounts.count > 4 ? 100 : 140)
            Text("Who’s watching?").font(.system(size: 30, weight: .bold, design: .rounded))
            PhoneSavedAccountCards(isSettings: false, editorRoute: $profileEditorRoute)
            Spacer()
            VividCopyrightFooter().padding(.bottom, 24)
        }
    }
}

/// One position in the Who's watching grid.
private enum PhoneProfileGridEntry: Identifiable {
    case account(TVSavedAccount)
    case add
    var id: String {
        switch self {
        case .account(let account): account.id
        case .add: "add-profile"
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
    /// A narrow glass bar of avatars for the iPhone Duo's side strip.
    var isStrip = false
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
            if isStrip {
                stripBar
            } else if isSettings {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: avatarSize, maximum: 112), spacing: 12, alignment: .top)], alignment: .leading, spacing: 16) {
                    profileCards
                }
            } else if displayedAccounts.count < 3 {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            profileCards
                        }
                        .padding(.vertical, 12)
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                }
                .frame(height: 170)
            } else if displayedAccounts.count >= 5 {
                // Five to eight: rows of three with the last row centred, and
                // Add Profile taking the next place in the grid.
                VStack(spacing: 24) {
                    ForEach(Array(gridEntries.profileRows(of: 3).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { entry in
                                switch entry {
                                case .account(let account): cardButton(account).frame(width: 118)
                                case .add: addProfileButton.frame(width: 118)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 24) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                              count: displayedAccounts.count == 3 ? 3 : min(2, max(1, displayedAccounts.count))), spacing: 24) {
                        accountCards
                    }
                    if store.canAddAccount { addProfileButton.frame(width: 112) }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)

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
                        } else { pinError = store.error ?? String(localized: "Incorrect PIN"); pin = "" }
                    }
                }
                .vividScrollContentBackgroundHidden()
                .background(Color.clear)
                .navigationTitle(account.displayName)
                .toolbar { VividSheetCloseItem { selectedForPIN = nil; pin = "" } }
            }.vividGlassSheet()
        }
    }
    private var avatarSize: CGFloat { isSettings ? 72 : 88 }

    /// The same taps as the cards; reordering stays with the full cards.
    private var stripBar: some View {
        VStack(spacing: 10) {
            ForEach(displayedAccounts) { account in
                Button { activateProfile(account) } label: {
                    ProfileAvatarView(avatar: account.profile?.avatarEmoji, imageUrl: savedAvatarURL(account), name: account.displayName, size: 36,
                                      cacheScope: account.profile.map {
                                          VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: $0.id)
                                      })
                        .overlay {
                            Circle().strokeBorder(isCurrentAccount(account) ? Color.white : .clear, lineWidth: 2)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCurrentAccount(account) ? String(localized: "\(account.displayName), current account") : account.displayName)
            }
            if store.canAddAccount {
                Button { editorRoute = .add } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Profile")
            }
        }
        .padding(.vertical, 7)
        .frame(width: 50)
        .vividGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
    }

    @ViewBuilder
    private var profileCards: some View {
        accountCards
        if store.canAddAccount { addProfileButton }
    }

    @ViewBuilder
    private var accountCards: some View {
        ForEach(displayedAccounts) { account in
            cardButton(account)
        }
    }

    private var gridEntries: [PhoneProfileGridEntry] {
        displayedAccounts.map(PhoneProfileGridEntry.account) + (store.canAddAccount ? [.add] : [])
    }

    private func cardButton(_ account: TVSavedAccount) -> some View {
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

    private var addProfileButton: some View {
        Button { editorRoute = .add } label: {
            VStack(spacing: isSettings ? 8 : 12) {
                Image(systemName: "plus").font(.system(size: 32))
                    .frame(width: avatarSize, height: avatarSize).background(.white.opacity(0.12), in: Circle())
                Text("Add Profile").font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(width: isSettings ? nil : 112)
                .frame(maxWidth: isSettings ? .infinity : nil)
        }
    }

    private func serverLabel(for account: TVSavedAccount) -> String {
        account.serverName ?? account.defaultServerLabel
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
            ProfileAvatarView(avatar: account.profile?.avatarEmoji, imageUrl: savedAvatarURL(account), name: account.displayName, size: avatarSize,
                              cacheScope: account.profile.map {
                                  VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: $0.id)
                              })
                .overlay {
                    Circle().strokeBorder(isSettings && isCurrentAccount(account) ? Color.white : .clear, lineWidth: 3)
                }
                .accessibilityLabel(isSettings && isCurrentAccount(account) ? String(localized: "Current account") : account.displayName)
            VStack(spacing: 4) {
                Text(account.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(serverLabel(for: account))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if store.needsLogin(account) { Text("Signed out").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(width: !isSettings && displayedAccounts.count < 3 ? 112 : nil)
            .frame(maxWidth: isSettings || displayedAccounts.count >= 3 ? .infinity : nil)
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
    @State private var household = SiloHouseholdSearch()
    @State private var codeSignIn = CodeSignIn()
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var account: TVSavedAccount? { store.accounts.first { $0.id == accountID } }
    private var active: Bool { accountID != nil && accountID == store.activeID && !store.showsSelector && AuthService.shared.isLoggedIn }
    var body: some View {
        List {
            SettingsPageHeader(title: Text(account?.displayName ?? String(localized: "Add Profile")), subtitle: Text("Account details and access on this device."), systemImage: "person.crop.circle").settingsPageHeaderRow()
            if account == nil {
                Section {
                    Picker("Server Provider", selection: $provider) {
                        Text(verbatim: "Silo").tag("Silo")
                        Text(verbatim: "Emby").tag("Emby")
                        Text(verbatim: "Jellyfin").tag("Jellyfin")
                    }
                    // Only servers of the chosen type, as on Apple TV.
                    let saved = registry.sortedEntries.filter { MediaServerProvider.forServerID($0.id) == selectedProvider }
                    if !saved.isEmpty {
                        Picker("Saved Server", selection: $serverURL) {
                            Text("Enter an address").tag("")
                            ForEach(saved) { Text($0.displayName).tag($0.url) }
                        }
                    }
                } header: { PhoneSettingsSectionHeader("Server") }
            }
            Section {
                if account == nil { TextField("Server address", text: $serverURL).keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                else { LabeledContent("Server", value: registry.entry(with: account!.serverID)?.url ?? serverURL) }
                if let name = account?.siloProfileName {
                    LabeledContent("Profile", value: name)
                    LabeledContent("Username") {
                        TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField("Password", text: $password).textContentType(.password)
                Button(account == nil ? "Add Profile" : store.needsLogin(account!) ? "Sign In" : "Update Login") {
                    Task {
                        let success = await store.authenticate(id: accountID, serverURL: serverURL, username: username, password: password, router: router, provider: MediaServerProvider(rawValue: provider.lowercased()) ?? .silo)
                        password = ""
                        if success { dismiss() } else { message = store.error }
                    }
                }.disabled((accountID == nil && !store.canAddAccount) || store.busy || (password.isEmpty && provider == "Silo") || username.isEmpty || serverURL.isEmpty)
                if let service = codeService, !codeSignIn.isActive {
                    Button("Use \(service.title)") { startCodeSignIn(service) }
                        .disabled((accountID == nil && !store.canAddAccount) || store.busy || serverURL.isEmpty)
                }
            } header: { PhoneSettingsSectionHeader("Account") }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            if codeSignIn.isActive {
                codeSignInSection
            }
            if active, let account, MediaServerProvider.forServerID(account.serverID) == .silo {
                householdSection(account)
            }
            if active, let accountID {
                Section {
                    SecureField("New PIN", text: $pin).keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $confirmPIN).keyboardType(.numberPad)
                    Button(store.hasPIN(accountID) ? "Change PIN" : "Set PIN") {
                        guard pin == confirmPIN else { message = String(localized: "The PINs don’t match."); return }
                        if store.setPIN(pin, accountID: accountID) { message = String(localized: "PIN saved"); pin = ""; confirmPIN = "" }
                        else { message = store.error }
                    }.disabled(store.busy)
                    if store.hasPIN(accountID) {
                        Button("Remove PIN") { message = store.removePIN(accountID) ? String(localized: "PIN removed") : String(localized: "Couldn’t remove the PIN.") }
                    }
                } header: { PhoneSettingsSectionHeader("PIN Protection") }
            }
            if account != nil {
                Section {
                    if active {
                        Button(role: .destructive) {
                            Task { await store.signOut(router: router) }
                        } label: {
                            Text("Sign Out")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    Button(role: .destructive) { showsDeleteConfirm = true } label: {
                        Text("Delete Profile")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(store.busy)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            VividCopyrightFooter().frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }.settingsListChrome().navigationTitle("")
        .sheet(item: $household.pinProfile) { profile in
            PINEntryView(profile: profile, onCancel: {
                if let account { household.cancelPIN(for: account) }
            }) { pin in
                if let account { Task { await household.add(profile, pin: pin, for: account) } }
            }
            .presentationDetents([.medium, .large])
            // Cancel signs out the session approved for this profile; a
            // swipe would leave it signed in with no saved profile.
            .interactiveDismissDisabled()
        }
        .confirmationDialog("Delete Profile?", isPresented: $showsDeleteConfirm,
                            titleVisibility: .visible, presenting: account) { account in
            Button("Delete Profile", role: .destructive) {
                Task {
                    if await store.deleteAccount(account.id, router: router) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("Remove \(account.displayName) and its saved connection from Vivid on your iCloud devices? Other profiles and the actual server account and library won’t be deleted.")
        }
        .onAppear {
            if let account {
                provider = MediaServerProvider.forServerID(account.serverID).name
                username = account.username
                serverURL = registry.entry(with: account.serverID)?.url ?? ""
            } else {
                // Start on the type of the server the address is filled from.
                serverURL = registry.activeServer?.url ?? ""
                if let active = registry.activeServer { provider = MediaServerProvider.forServerID(active.id).name }
            }
        }
        .onDisappear { codeSignIn.cancel() }
        .onChange(of: provider) {
            if codeSignIn.canCancel { codeSignIn.cancel() }
            if account == nil { serverURL = registry.address(serverURL, keptFor: selectedProvider) }
        }
        .onChange(of: serverURL) { if codeSignIn.canCancel { codeSignIn.cancel() } }
    }

    private var selectedProvider: MediaServerProvider {
        MediaServerProvider(rawValue: provider.lowercased()) ?? .silo
    }

    private var codeService: CodeSignIn.Service? {
        MediaServerProvider(rawValue: provider.lowercased()).flatMap(CodeSignIn.Service.init)
    }

    /// Quick Connect or Emby Connect: the code to approve somewhere else.
    private var codeSignInSection: some View {
        Section {
            if let code = codeSignIn.code {
                LabeledContent(codeSignIn.service.codeTitle) {
                    Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                }
            }
            if let status = codeSignIn.status {
                HStack(spacing: 12) {
                    VividLoadingDots(compact: true)
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if let failure = codeSignIn.failure {
                Text(failure).foregroundStyle(.secondary)
                Button("Get a New \(codeSignIn.service.codeTitle)") { startCodeSignIn(codeSignIn.service) }
            }
            Button("Cancel", role: .cancel) { codeSignIn.cancel() }
                .disabled(!codeSignIn.canCancel)
        } header: { PhoneSettingsSectionHeader(codeSignIn.service.title) } footer: {
            Text(codeSignIn.service.instructions)
        }
    }

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        message = nil
        let address = account.flatMap { registry.entry(with: $0.serverID)?.url } ?? registry.normalizedUserAddress(serverURL)
        let accountID = accountID
        let fallback = String(localized: "Couldn’t finish signing in with \(service.title). Please try again.")
        switch service {
        case .jellyfinQuickConnect:
            codeSignIn.startQuickConnect(serverURL: address) { login in
                let success = await store.authenticate(id: accountID, serverURL: address, username: login.username, password: "",
                                                       router: router, provider: .jellyfin, quickConnect: login)
                if success { dismiss() }
                return success ? nil : store.error ?? fallback
            }
        case .embyConnect:
            codeSignIn.startEmbyConnect(serverURL: address) { login in
                let success = await store.authenticate(id: accountID, serverURL: address, username: login.username, password: "",
                                                       router: router, provider: .emby, embyConnect: login)
                if success { dismiss() }
                return success ? nil : store.error ?? fallback
            }
        }
    }

    /// Finds the other profiles on this Silo login and adds them here.
    @ViewBuilder
    private func householdSection(_ account: TVSavedAccount) -> some View {
        Section {
            switch household.phase {
            case .idle:
                Button("Search for Accounts") { Task { await household.search(for: account) } }
            case .searching:
                HStack(spacing: 12) {
                    VividLoadingDots(compact: true)
                    Text("Searching for accounts").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            case .results:
                if !household.profiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(household.profiles) { profile in
                                Button { Task { await household.choose(profile, for: account) } } label: {
                                    SiloHouseholdTile(profile: profile, account: account,
                                                      isAdding: household.addingID == profile.id)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .disabled(household.addingID != nil)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                Button("Search Again") { Task { await household.search(for: account) } }
            case .failed:
                Button("Try Again") { Task { await household.search(for: account) } }
            }
            if let message = household.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            PhoneSettingsSectionHeader("Household")
        } footer: {
            Text("Find the other profiles on this Silo account and add them to this device. Each one gets its own Vivid profile.")
        }
    }
}
#endif
