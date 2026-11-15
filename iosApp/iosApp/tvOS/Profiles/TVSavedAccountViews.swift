#if os(tvOS)
import SwiftUI

private struct WallKey: Hashable {
    let accounts: [TVSavedAccount]
    let revision: Int
}

/// Who's watching: the saved profiles at launch, on an arc over a drifting
/// wall of library posters. Choosing one plays the startup animation over
/// the page before the app takes over.
struct TVSavedProfilesScreen: View {
    let router: AppRouter
    @State private var store = TVSavedAccountStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFinishingHandoff = false
    @State private var path = NavigationPath()
    @State private var posters: [UIImage] = []
    @State private var wall = TVPosterWallStore.revision
    /// The centred profile's colour, for the wall's glow.
    @State private var glowHue: Double?
    private var handoffDuration: Double { reduceMotion ? 0.2 : 0.55 }

    var body: some View {
        ZStack {
            TVAppBackdrop()
            NavigationStack(path: $path) {
                VStack(spacing: 0) {
                    Text("Who’s watching?")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 84)
                    Spacer(minLength: 0)
                    TVProfileOrbit { route in
                        path.append(route)
                    } onSelectionChange: { account in
                        glowHue = account.map(TVProfileOrbitPlace.hue(for:))
                    }
                    Spacer(minLength: 0)
                    if let error = store.error {
                        Text(error).font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1000)
                    }
                    Spacer().frame(height: 120)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TVPosterWall(posters: posters, glowHue: glowHue) }
                .overlay(alignment: .bottom) {
                    VividCopyrightFooter()
                        .padding(.bottom, 40)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: TVAccountRoute.self) { route in
                    switch route {
                    case .editor(let id): TVSavedAccountEditor(accountID: id)
                    case .profiles: TVSettingsProfilesPage()
                    }
                }
            }
            .opacity(store.showsAnimation ? 0 : 1)
            .animation(
                .easeInOut(duration: handoffDuration * 0.6).delay(handoffDuration * 0.4),
                value: store.showsAnimation
            )
            .disabled(store.showsAnimation || isFinishingHandoff)
            .accessibilityHidden(store.showsAnimation || isFinishingHandoff)
            if store.showsAnimation {
                VividStartupView(isContentReady: true) {
                    isFinishingHandoff = true
                    withAnimation(.easeInOut(duration: handoffDuration * 0.4)) {
                        store.showsAnimation = false
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .environment(router)
        // Again when posters are saved while the page is up, as when the
        // signed-in profile's Home loads behind it at launch.
        .task(id: WallKey(accounts: store.accounts, revision: wall.value)) {
            posters = await TVPosterWallStore.posters(for: store.accounts)
        }
        .task(id: isFinishingHandoff) {
            guard isFinishingHandoff else { return }
            do { try await Task.sleep(for: .seconds(handoffDuration)) } catch { return }
            isFinishingHandoff = false
        }
    }
}

struct TVAccountCircleStyle: ButtonStyle {
    /// Matches the card's own scale so the focus ring keeps circling a
    /// larger avatar.
    var scale: CGFloat = 1
    func makeBody(configuration: Configuration) -> some View { CircleBody(configuration: configuration, scale: scale) }
    private struct CircleBody: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .overlay(alignment: .top) {
                    Circle().strokeBorder(focused ? Color.white : .clear, lineWidth: 3)
                        .frame(width: (116 * scale).rounded(), height: (116 * scale).rounded())
                        .offset(y: (-4 * scale).rounded())
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (focused ? 1.05 : 1))
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// One saved profile's settings, or adding a profile (and its server): the
/// login, code sign-in and deleting, plus the PIN, the Silo household and
/// signing out for the signed-in profile.
struct TVSavedAccountEditor: View {
    let accountID: String?
    var addingServer = false
    var selectedServerProvider: MediaServerProvider? = nil
    @State private var provider = "Silo"
    @State private var registry = ServerRegistry.shared
    @State private var store = TVSavedAccountStore.shared
    @State private var username = ""
    @State private var password = ""
    @State private var serverURL = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var showsDeleteConfirm = false
    @State private var pinIsSet = false
    @State private var household = SiloHouseholdSearch()
    @State private var codeSignIn = CodeSignIn()
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var account: TVSavedAccount? { store.accounts.first { $0.id == accountID } }
    private var selectedProvider: MediaServerProvider {
        account.map { MediaServerProvider.forServerID($0.serverID) }
            ?? selectedServerProvider
            ?? (MediaServerProvider(rawValue: provider.lowercased()) ?? .silo)
    }
    private var isActive: Bool { accountID != nil && accountID == store.activeID && !store.showsSelector && AuthService.shared.isLoggedIn }
    private static var busyHint: String { String(localized: "Vivid is still working on this profile. You can go back once it’s finished.") }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(30)) {
                HStack(spacing: TVSettingsLayout.scaled(20)) {
                    Image(systemName: "person.crop.circle")
                        .font(.tvSettings(27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: TVSettingsLayout.scaled(62), height: TVSettingsLayout.scaled(62))
                        .background(
                            Color(red: 0.12, green: 0.13, blue: 0.15),
                            in: RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(15.5), style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(7)) {
                        (account.map { Text($0.displayName) } ?? Text(addingServer ? "Add Server" : "Add Profile"))
                            .font(.tvSettings(40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Account details and access on this Apple TV.")
                            .font(.tvSettings(20)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, TVSettingsLayout.scaled(12))

                if account == nil {
                    if selectedServerProvider == nil {
                        TVSettingsSectionHeader("SERVER TYPE")
                        TVSettingsGroup {
                            ForEach(["Silo", "Emby", "Jellyfin"], id: \.self) { option in
                                Button {
                                    provider = option
                                    password = ""
                                    store.error = nil
                                } label: {
                                    HStack {
                                        TVSettingsRowLabel(title: option, detail: nil)
                                        Spacer()
                                        if provider == option { Image(systemName: "checkmark") }
                                    }
                                }
                                .buttonStyle(TVSettingsPaneRowStyle())
                            }
                        }
                    }
                    if registry.sortedEntries.contains(where: { MediaServerProvider.forServerID($0.id) == selectedProvider }) {
                        TVSettingsSectionHeader("SAVED SERVERS")
                        TVSettingsGroup {
                            ForEach(registry.sortedEntries.filter { MediaServerProvider.forServerID($0.id) == selectedProvider }) { entry in
                                Button {
                                    serverURL = entry.url
                                    password = ""
                                } label: {
                                    HStack {
                                        TVSettingsRowLabel(title: entry.displayName, detail: entry.url)
                                        Spacer()
                                        if ServerRegistry.normalize(url: serverURL) == entry.url {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .buttonStyle(TVSettingsPaneRowStyle())
                            }
                        }
                    }
                }
                Group {
                    TVSettingsSectionHeader("ACCOUNT")
                    TVSettingsGroup {
                        if account == nil {
                            TVSettingsFieldRow(title: "Server address", detail: "The address of your media server.") {
                                TextField("Server address", text: $serverURL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        } else {
                            TVSettingsInfoRow(title: "Server", value: ServerRegistry.shared.entry(with: account!.serverID)?.displayName ?? serverURL)
                            if let name = account!.siloProfileName {
                                TVSettingsInfoRow(title: "Profile", value: name)
                            }
                        }
                        TVSettingsFieldRow(title: "Username", detail: "Your username on this server.") {
                            TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        TVSettingsFieldRow(title: "Password", detail: "Enter the current password to update your saved login.") {
                            SecureField("Password", text: $password).textContentType(.password)
                        }
                        Button {
                            Task {
                                _ = await store.authenticate(id: accountID, serverURL: serverURL,
                                    username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, router: router, provider: selectedProvider)
                                password = ""
                            }
                        } label: {
                            TVSettingsRowLabel(title: account?.requiresLogin == true ? "Sign In" : (account == nil ? (addingServer ? "Add Server & Profile" : "Add Profile") : "Update Login"),
                                               detail: "Validate and save this account’s login on the Apple TV.")
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (password.isEmpty && !selectedProvider.usesNativeUser))
                        if let service = CodeSignIn.Service(selectedProvider) {
                            // One row for starting and replacing a code, so focus stays put.
                            Button { startCodeSignIn(service) } label: {
                                TVSettingsRowLabel(title: codeSignIn.isActive ? Text(service.getNewTitle) : Text("Use \(service.title)"),
                                                   detail: codeSignIn.isActive ? Text(service.replaceBelowText) : Text(service.summary))
                            }
                            .buttonStyle(TVSettingsPaneRowStyle())
                            .disabled((accountID == nil && !store.canAddAccount) || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if account == nil {
                        TVSettingsFooter("Signing in saves this profile and its server together. Saved servers are available in Manage Servers and when adding another profile.")
                    }
                    if codeSignIn.isActive {
                        TVSettingsSectionHeader(codeSignIn.service.title.uppercased())
                        TVSettingsGroup {
                            if let code = codeSignIn.code {
                                TVSettingsInfoRow(title: codeSignIn.service.codeTitle, value: code)
                            }
                            if let status = codeSignIn.status {
                                TVSettingsInfoRow(title: "Status", value: status)
                            }
                            if let failure = codeSignIn.failure {
                                TVSettingsInfoRow(title: "Status", value: failure)
                            }
                            Button { if codeSignIn.canCancel { codeSignIn.cancel() } } label: {
                                TVSettingsRowLabel(title: "Cancel \(codeSignIn.service.title)")
                            }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        }
                        TVSettingsFooter(codeSignIn.service.instructions)
                    }
                }
                if isActive, let account, MediaServerProvider.forServerID(account.serverID) == .silo {
                    householdSection(account)
                }
                if isActive, let account {
                    TVSettingsSectionHeader("ACCOUNT PIN")
                    TVSettingsGroup {
                        TVSettingsFieldRow(title: "New PIN", detail: "Optional: use four digits to protect account entry.") {
                            SecureField("New four-digit PIN", text: $pin)
                        }
                        TVSettingsFieldRow(title: "Confirm PIN", detail: "Enter the same four digits again.") {
                            SecureField("Confirm PIN", text: $confirmation)
                        }
                        Button {
                            guard pin == confirmation else { message = String(localized: "The PINs don’t match."); return }
                            if store.setPIN(pin, accountID: account.id) {
                                pinIsSet = true; pin = ""; confirmation = ""; message = String(localized: "PIN saved.")
                            }
                        } label: { TVSettingsRowLabel(title: pinIsSet ? "Change PIN" : "Set PIN") }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        if pinIsSet {
                            Button {
                                if store.removePIN(account.id) { pinIsSet = false; message = String(localized: "PIN removed.") }
                            } label: { TVSettingsRowLabel(title: "Remove PIN") }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        }
                    }
                    TVSettingsSectionHeader("SESSION")
                    TVSettingsGroup {
                        Button(role: .destructive) { Task { await store.signOut(router: router) } }
                        label: { TVSettingsRowLabel(title: "Sign Out") }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                    }
                }
                if account != nil {
                    TVSettingsGroup {
                        Button(role: .destructive) { showsDeleteConfirm = true } label: {
                            TVSettingsRowLabel(title: "Delete Profile")
                        }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                    }
                }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.tvSettings(21)) }
                if let message { Text(message).font(.tvSettings(21)) }
                if store.busy { ProgressView() }
            }
            .frame(maxWidth: TVSettingsLayout.scaled(1080), alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.top, TVSettingsLayout.scaled(48)).padding(.bottom, TVSettingsLayout.scaled(64))
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop())
        .toolbar(.hidden, for: .navigationBar)
        .disabled(store.busy)
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
            username = account?.username ?? ""
            serverURL = account.flatMap { ServerRegistry.shared.entry(with: $0.serverID)?.url } ?? (addingServer ? "" : ServerRegistry.shared.activeServerUrl)
            // Start on the type of the server the address is filled from.
            if account == nil, selectedServerProvider == nil, !addingServer, let active = registry.activeServer {
                provider = MediaServerProvider.forServerID(active.id).name
            }
            pinIsSet = accountID.map { store.hasPIN($0) } ?? false
            store.error = nil
        }
        .onDisappear { password = ""; pin = ""; confirmation = ""; codeSignIn.cancel() }
        .onChange(of: provider) {
            if codeSignIn.canCancel { codeSignIn.cancel() }
            if account == nil { serverURL = registry.address(serverURL, keptFor: selectedProvider) }
        }
        .onChange(of: serverURL) { if codeSignIn.canCancel { codeSignIn.cancel() } }
        .onExitCommand {
            // A sign-in, sign-out or deletion holds the account switch until
            // it finishes and can't be stopped partway, so Menu says to wait
            // instead of doing nothing.
            if store.busy {
                message = Self.busyHint
            } else {
                dismiss()
            }
        }
        .onChange(of: store.busy) { _, busy in
            if !busy, message == Self.busyHint { message = nil }
        }
        .fullScreenCover(item: $household.pinProfile) { profile in
            PINEntryView(profile: profile, onCancel: {
                if let account { household.cancelPIN(for: account) }
            }) { pin in
                if let account { Task { await household.add(profile, pin: pin, for: account) } }
            }
        }
    }

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        store.error = nil
        let address = account.flatMap { registry.entry(with: $0.serverID)?.url } ?? registry.normalizedUserAddress(serverURL)
        let accountID = accountID
        let fallback = String(localized: "Couldn’t finish signing in with \(service.title). Please try again.")
        switch service {
        case .jellyfinQuickConnect:
            codeSignIn.startQuickConnect(serverURL: address) { login in
                let success = await store.authenticate(id: accountID, serverURL: address, username: login.username, password: "",
                                                       router: router, provider: .jellyfin, quickConnect: login)
                return success ? nil : store.error ?? fallback
            }
        case .embyConnect:
            codeSignIn.startEmbyConnect(serverURL: address) { login in
                let success = await store.authenticate(id: accountID, serverURL: address, username: login.username, password: "",
                                                       router: router, provider: .emby, embyConnect: login)
                return success ? nil : store.error ?? fallback
            }
        }
    }

    /// Finds the other profiles on this Silo login and adds them here.
    @ViewBuilder
    private func householdSection(_ account: TVSavedAccount) -> some View {
        TVSettingsSectionHeader("HOUSEHOLD")
        TVSettingsGroup {
            switch household.phase {
            case .idle, .failed:
                Button { Task { await household.search(for: account) } } label: {
                    TVSettingsRowLabel(title: household.phase == .failed ? "Try Again" : "Search for Accounts",
                                       detail: "Find the other profiles on this Silo account and add them to this Apple TV.")
                }
                .buttonStyle(TVSettingsPaneRowStyle())
            case .searching:
                HStack(spacing: TVSettingsLayout.scaled(18)) {
                    VividLoadingDots()
                    Text("Searching for accounts")
                        .font(.tvSettings(24, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: TVSettingsLayout.scaled(96))
            case .results:
                if !household.profiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: TVSettingsLayout.scaled(32)) {
                            ForEach(household.profiles) { profile in
                                Button { Task { await household.choose(profile, for: account) } } label: {
                                    SiloHouseholdTile(profile: profile, account: account,
                                                      isAdding: household.addingID == profile.id,
                                                      avatarSize: TVSettingsLayout.scaled(108))
                                }
                                .buttonStyle(TVAccountCircleStyle(scale: TVSettingsLayout.scale))
                                .disabled(household.addingID != nil)
                            }
                        }
                        .padding(TVSettingsLayout.scaled(24))
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
                Button { Task { await household.search(for: account) } } label: {
                    TVSettingsRowLabel(title: "Search Again", detail: nil)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
            }
        }
        if let message = household.message {
            TVSettingsFooter(message)
        }
    }
}

/// Asks for a profile's PIN before entering it.
struct TVSavedAccountPINPrompt: View {
    let account: TVSavedAccount
    let onPIN: (String) -> Void
    @State private var pin = ""
    @State private var store = TVSavedAccountStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 28) {
            Text(account.displayName).font(.system(size: 42, weight: .bold))
            SecureField("Four-digit PIN", text: $pin).frame(width: 480)
            Button("Unlock") { onPIN(pin); pin = "" }
                .buttonStyle(TVSettingsPaneRowStyle()).frame(width: 480)
            if let error = store.error { Text(error).font(.system(size: 22)) }
            Button("Cancel") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { TVAppBackdrop() }
        .onExitCommand { dismiss() }
        .onDisappear { pin = "" }
    }
}
#endif
