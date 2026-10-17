#if os(tvOS)
import SwiftUI

struct TVSavedProfilesScreen: View {
    let router: AppRouter
    @State private var store = TVSavedAccountStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFinishingHandoff = false
    private var handoffDuration: Double { reduceMotion ? 0.2 : 0.55 }

    var body: some View {
        ZStack {
            TVAppBackdrop()
            NavigationStack {
                VStack(spacing: 28) {
                    VividLogoView(size: 280)
                    Text("Who’s watching?")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    TVSavedAccountCards(isSettings: false)
                        .frame(maxWidth: 1720)
                    if let error = store.error {
                        Text(error).font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1000)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TVAppBackdrop() }
                .overlay(alignment: .bottom) {
                    VividCopyrightFooter()
                        .padding(.bottom, 40)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: TVAccountRoute.self) { route in
                    switch route { case .editor(let id): TVSavedAccountEditor(accountID: id) }
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
        .task(id: isFinishingHandoff) {
            guard isFinishingHandoff else { return }
            do { try await Task.sleep(for: .seconds(handoffDuration)) } catch { return }
            isFinishingHandoff = false
        }
    }
}

struct TVSavedAccountCards: View {
    var isSettings = true
    @Environment(\.isEnabled) private var isEnabled
    @State private var hasRequestedInitialProfileFocus = false
    @Namespace private var profileFocusScope
    @FocusState private var focusedAccount: String?
    @State private var store = TVSavedAccountStore.shared
    @State private var registry = ServerRegistry.shared
    @State private var pinAccount: TVSavedAccount?
    @State private var isEditingProfiles = false
    @State private var draftOrder: [String] = []
    @State private var movingID: String?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editingFocused: Bool
    @State private var profileStore = CurrentProfileStore.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        GeometryReader { viewport in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: metric(32)) {
                ForEach(displayedAccounts) { account in
                    if isEditingProfiles {
                        if account.id == movingID {
                            Button { finishArrangement() } label: {
                                tile(account)
                                    .overlay(alignment: .top) {
                                        Circle().strokeBorder(.white, lineWidth: 3)
                                            .frame(width: metric(112), height: metric(112))
                                    }
                                    .modifier(ProfileArrangeWobble(active: true))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .focused($editingFocused)
                            .onAppear { editingFocused = true }
                            .onMoveCommand { direction in
                                switch direction {
                                case .left: moveDraft(account.id, by: -1)
                                case .right: moveDraft(account.id, by: 1)
                                default: break
                                }
                            }
                            .onExitCommand { cancelArrangement() }
                            .accessibilityLabel("Move \(account.displayName). Move left or right, then press centre to drop and save.")
                        } else {
                            tile(account).modifier(ProfileArrangeWobble(active: true))
                        }
                    } else {
                        Group {
                            if (isSettings && account.id == store.activeID) || store.needsLogin(account) {
                                NavigationLink(value: TVAccountRoute.editor(account.id)) { tile(account) }
                                    .buttonStyle(TVAccountCircleStyle(scale: scale))
                                    .focused($focusedAccount, equals: account.id)
                                    .prefersDefaultFocus(account.id == store.accounts.first?.id, in: profileFocusScope)

                            } else {
                                Button {
                                    if store.hasPIN(account.id) { pinAccount = account }
                                    else { Task { await store.select(account, router: router) } }
                                } label: { tile(account) }
                                .buttonStyle(TVAccountCircleStyle(scale: scale))
                                    .focused($focusedAccount, equals: account.id)
                                    .prefersDefaultFocus(account.id == store.accounts.first?.id, in: profileFocusScope)

                            }
                        }
                        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginArrangement(account.id) })
                        .accessibilityAction(named: "Arrange Profiles") { beginArrangement(account.id) }
                    }
                }
                if store.canAddAccount {
                    NavigationLink(value: TVAccountRoute.editor(nil)) {
                        VStack(spacing: metric(14)) {
                            Image(systemName: "plus").font(.system(size: metric(46), weight: .medium))
                                .frame(width: metric(108), height: metric(108))
                                .background(.white.opacity(0.12), in: Circle())
                            Text("Add Profile").font(.system(size: metric(20), weight: .medium))
                        }.frame(width: metric(142))
                    }
                    .buttonStyle(TVAccountCircleStyle(scale: scale))
                    .disabled(isEditingProfiles)
                }
            }
            .padding(metric(16))
            .frame(minWidth: viewport.size.width, alignment: isSettings ? .leading : .center)
        }
        .scrollClipDisabled()
        }
        .frame(height: metric(222))
        .disabled(store.busy || pinAccount != nil)
        .task {
            await profileStore.refresh(force: true)
            await store.captureCurrent()
        }
        .focusSection()
        .focusScope(profileFocusScope)
        .defaultFocus($focusedAccount, store.accounts.first?.id, priority: .userInitiated)
        .task(id: initialProfileFocusID) {
            guard let target = initialProfileFocusID, !hasRequestedInitialProfileFocus else { return }
            // Enabling the row and removing the splash must reach the native
            // view tree before assigning focus to its first button.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled, !hasRequestedInitialProfileFocus,
                  initialProfileFocusID == target else { return }
            focusedAccount = target
        }
        .onChange(of: focusedAccount) { _, accountID in
            if accountID != nil, initialProfileFocusID != nil {
                hasRequestedInitialProfileFocus = true
            }
        }
        .task(id: scenePhase == .active && !isEditingProfiles) {
            guard scenePhase == .active, !isEditingProfiles else { return }
            while !Task.isCancelled {
                await VividCloudAccountSync.shared.synchronize(router: router)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelArrangement() }
        }
        .onDisappear { cancelArrangement() }
        .alert("Profile", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .fullScreenCover(item: $pinAccount) { account in
            TVSavedAccountPINPrompt(account: account) { pin in
                if store.unlock(account.id, pin: pin) {
                    pinAccount = nil
                    Task { await store.select(account, router: router) }
                }
            }
        }
    }

    /// The row follows the settings scale inside Settings; the profile
    /// picker keeps its own size.
    private var scale: CGFloat { isSettings ? TVSettingsLayout.scale : 1 }
    private func metric(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    private var initialProfileFocusID: String? {
        guard !isSettings, isEnabled, scenePhase == .active, !store.busy, !store.showsAnimation,
              store.error == nil,
              pinAccount == nil, !isEditingProfiles else { return nil }
        return store.accounts.first?.id
    }

    private var displayedAccounts: [TVSavedAccount] {
        guard isEditingProfiles else { return store.accounts }
        let ids = VividCloudPreferencePolicy.ordered(store.accounts.map(\.id), preferred: draftOrder)
        let byID = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }
    private func beginArrangement(_ id: String) {
        guard !store.busy, store.accounts.count > 1 else { return }
        draftOrder = store.accounts.map(\.id)
        movingID = id
        isEditingProfiles = true
    }
    private func finishArrangement() {
        _ = store.saveAccountOrder(draftOrder)
        cancelArrangement()
    }
    private func cancelArrangement() {
        let returnID = movingID
        isEditingProfiles = false
        movingID = nil
        draftOrder = []
        if let returnID { focusedAccount = returnID }
    }
    private func moveDraft(_ id: String, by offset: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            draftOrder = VividCloudPreferencePolicy.moving(draftOrder, id: id, by: offset)
        }
    }
    private func serverLabel(for account: TVSavedAccount) -> String {
        if MediaServerProvider.forServerID(account.serverID).usesNativeUser { return MediaServerProvider.forServerID(account.serverID).name }
        return registry.entry(with: account.serverID)?.displayName ?? "Media server"
    }

    private func tile(_ account: TVSavedAccount) -> some View {
        VStack(spacing: metric(14)) {
            ProfileAvatarView(avatar: displayedProfile(account)?.avatarEmoji,
                              imageUrl: avatarURL(account), name: account.displayName, size: metric(108),
                              cacheScope: displayedProfile(account).map {
                                  VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: String($0.id))
                              })
                .overlay { TVCurrentAccountRing(isCurrent: isSettings && isCurrentAccount(account)) }
            VStack(spacing: metric(5)) {
                Text(account.displayName).font(.system(size: metric(20), weight: .medium)).lineLimit(1)
                Text(serverLabel(for: account))
                    .font(.system(size: metric(17))).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if account.requiresLogin { Text("Signed out").font(.system(size: metric(15))).opacity(0.6) }
            }
        }
        .frame(width: metric(142))
        .accessibilityLabel(account.displayName + (account.requiresLogin ? ", signed out" : "")
            + ", " + serverLabel(for: account)
            + (isSettings && isCurrentAccount(account) ? ", current account" : ""))
    }
    private func isCurrentAccount(_ account: TVSavedAccount) -> Bool {
        account.id == store.activeID && !account.requiresLogin && AuthService.shared.isLoggedIn
            && account.serverID == ServerRegistry.shared.activeServerId
    }
    private func displayedProfile(_ account: TVSavedAccount) -> UserProfile? {
        if isCurrentAccount(account), let profile = profileStore.profile,
           profile.id == AuthService.shared.profileId { return profile }
        return account.profile
    }
    private func avatarURL(_ account: TVSavedAccount) -> String? {
        guard let raw = displayedProfile(account)?.avatarImageUrl else { return nil }
        if raw.hasPrefix("/"), let server = ServerRegistry.shared.entry(with: account.serverID) {
            return server.url + raw
        }
        return raw
    }
}

/// Marks the signed-in account in Settings. It steps aside while the card
/// has focus, where the focus ring already circles the avatar and the two
/// rings would read as one doubled outline.
private struct TVCurrentAccountRing: View {
    let isCurrent: Bool
    @Environment(\.isFocused) private var isFocused
    var body: some View {
        Circle().strokeBorder(isCurrent && !isFocused ? Color.white : .clear, lineWidth: 3)
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
                        Text(account == nil ? (addingServer ? "Add Server" : "Add Profile") : account!.displayName)
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
                                        TVSettingsRowLabel(title: option,
                                            detail: nil)
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
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
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
                            TVSettingsRowLabel(title: codeSignIn.isActive ? "Get a New \(service.codeTitle)" : "Use \(service.title)",
                                               detail: codeSignIn.isActive ? "Replace the \(service.codeName) below with a new one."
                                                   : service == .embyConnect ? "Sign in with a PIN entered at emby.media/pin, without a password."
                                                   : "Approve this Apple TV from Jellyfin on a signed-in device, without a password.")
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
                            guard pin == confirmation else { message = "The PINs don’t match."; return }
                            if store.setPIN(pin, accountID: account.id) {
                                pinIsSet = true; pin = ""; confirmation = ""; message = "PIN saved."
                            }
                        } label: { TVSettingsRowLabel(title: pinIsSet ? "Change PIN" : "Set PIN") }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        if pinIsSet {
                            Button {
                                if store.removePIN(account.id) { pinIsSet = false; message = "PIN removed." }
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
            pinIsSet = accountID.map { store.hasPIN($0) } ?? false
            store.error = nil
        }
        .onDisappear { password = ""; pin = ""; confirmation = ""; codeSignIn.cancel() }
        .onChange(of: provider) { codeSignIn.cancel() }
        .onExitCommand { if !store.busy { dismiss() } }
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
        let fallback = "Couldn’t finish signing in with \(service.title). Please try again."
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

private struct TVSavedAccountPINPrompt: View {
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
