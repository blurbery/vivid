#if os(tvOS)
import SwiftUI

struct TVSavedProfilesScreen: View {
    let router: AppRouter
    @State private var store = TVSavedAccountStore.shared
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NavigationStack {
                VStack(spacing: 28) {
                    VividLogoView(size: 280)
                    Text("Who’s watching?")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    TVSavedAccountCards(isSettings: false)
                        .frame(maxWidth: 1200)
                    if let error = store.error {
                        Text(error).font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1000)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .overlay(alignment: .bottom) {
                    VividCopyrightFooter()
                        .padding(.bottom, 40)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: TVAccountRoute.self) { route in
                    switch route { case .editor(let id): TVSavedAccountEditor(accountID: id) }
                }
            }
            .disabled(store.showsAnimation)
            if store.showsAnimation {
                VividStartupView(isContentReady: true) { store.showsAnimation = false }
            }
        }
        .environment(router)
    }
}

struct TVSavedAccountCards: View {
    var isSettings = true
    @Namespace private var profileFocusScope
    @FocusState private var focusedAccount: String?
    @State private var store = TVSavedAccountStore.shared
    @State private var pinAccount: TVSavedAccount?
    @State private var pendingDeletion: TVSavedAccount?
    @State private var profileStore = CurrentProfileStore.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        GeometryReader { viewport in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 32) {
                ForEach(store.accounts) { account in
                    if (isSettings && account.id == store.activeID) || store.needsLogin(account) {
                        NavigationLink(value: TVAccountRoute.editor(account.id)) { tile(account) }
                            .buttonStyle(TVAccountCircleStyle())
                            .focused($focusedAccount, equals: account.id)
                            .contextMenu { deletionMenu(for: account) }
                    } else {
                        Button {
                            if store.hasPIN(account.id) { pinAccount = account }
                            else { Task { await store.select(account, router: router) } }
                        } label: { tile(account) }
                        .buttonStyle(TVAccountCircleStyle())
                            .focused($focusedAccount, equals: account.id)
                            .contextMenu { deletionMenu(for: account) }
                    }
                }
                NavigationLink(value: TVAccountRoute.editor(nil)) {
                    VStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 46, weight: .medium))
                            .frame(width: 108, height: 108)
                            .background(.white.opacity(0.12), in: Circle())
                        Text("Add Profile").font(.system(size: 20, weight: .medium))
                    }.frame(width: 142)
                }
                .buttonStyle(TVAccountCircleStyle())
            }
            .padding(16)
            .frame(minWidth: viewport.size.width, alignment: isSettings ? .leading : .center)
        }
        .scrollClipDisabled()
        }
        .frame(height: 190)
        .disabled(store.busy || pinAccount != nil)
        .task {
            await profileStore.refresh(force: true)
            await store.captureCurrent()
        }
        .focusSection()
        .focusScope(profileFocusScope)
        .defaultFocus($focusedAccount, store.accounts.first?.id, priority: .userInitiated)
        .confirmationDialog("Delete Profile?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { account in
            Button("Delete Profile", role: .destructive) {
                Task { await store.deleteAccount(account.id, router: router) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { account in
            Text("Remove \(account.username) and its saved connection from Vivid on your iCloud devices? Other profiles and the actual server account and library won’t be deleted.")
        }
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

    @ViewBuilder
    private func deletionMenu(for account: TVSavedAccount) -> some View {
        if isSettings || account.requiresLogin {
            Button("Delete Profile", systemImage: "trash", role: .destructive) {
                pendingDeletion = account
            }
        }
    }

    private func tile(_ account: TVSavedAccount) -> some View {
        VStack(spacing: 14) {
            ProfileAvatarView(avatar: displayedProfile(account)?.avatarEmoji,
                              imageUrl: avatarURL(account), name: account.username, size: 108)
                .overlay {
                    Circle().strokeBorder(isSettings && isCurrentAccount(account) ? Color.white : .clear, lineWidth: 3)
                }
            Text(account.username).font(.system(size: 20, weight: .medium)).lineLimit(1)
            if account.requiresLogin { Text("Signed out").font(.system(size: 15)).opacity(0.6) }
        }
        .frame(width: 142)
        .accessibilityLabel(account.username + (account.requiresLogin ? ", signed out" : "")
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

private struct TVAccountCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CircleBody(configuration: configuration) }
    private struct CircleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .overlay(alignment: .top) {
                    Circle().strokeBorder(focused ? Color.white : .clear, lineWidth: 3)
                        .frame(width: 116, height: 116).offset(y: -4)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (focused ? 1.05 : 1))
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

struct TVSavedAccountEditor: View {
    let accountID: String?
    var addingServer = false
    @State private var provider = "Silo"
    @State private var registry = ServerRegistry.shared
    @State private var store = TVSavedAccountStore.shared
    @State private var username = ""
    @State private var password = ""
    @State private var serverURL = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var pinIsSet = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private var account: TVSavedAccount? { store.accounts.first { $0.id == accountID } }
    private var selectedProvider: MediaServerProvider {
        account.map { MediaServerProvider.forServerID($0.serverID) }
            ?? (provider == "Emby" ? .emby : .silo)
    }
    private var isActive: Bool { accountID != nil && accountID == store.activeID && !store.showsSelector && AuthService.shared.isLoggedIn }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 20) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 62, height: 62)
                        .background(
                            Color(red: 0.12, green: 0.13, blue: 0.15),
                            in: RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 7) {
                        Text(account == nil ? (addingServer ? "Add Server" : "Add Profile") : account!.username)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Account details and access on this Apple TV.")
                            .font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 12)

                if account == nil {
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
                                        detail: option == "Jellyfin" ? "Coming soon" : nil)
                                    Spacer()
                                    if provider == option { Image(systemName: "checkmark") }
                                }
                            }
                            .buttonStyle(TVSettingsPaneRowStyle())
                        }
                    }
                    if provider != "Jellyfin", registry.sortedEntries.contains(where: { MediaServerProvider.forServerID($0.id) == selectedProvider }) {
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
                if account != nil || provider != "Jellyfin" {
                TVSettingsSectionHeader("ACCOUNT")
                TVSettingsGroup {
                    if account == nil {
                        TVSettingsFieldRow(title: "Server address", detail: "The address of your media server.") {
                            TextField("Server address", text: $serverURL).textContentType(.URL)
                        }
                    } else {
                        TVSettingsInfoRow(title: "Server", value: ServerRegistry.shared.entry(with: account!.serverID)?.displayName ?? serverURL)
                    }
                    TVSettingsFieldRow(title: "Username", detail: "Your username on this server.") {
                        TextField("Username", text: $username).textContentType(.username)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    TVSettingsFieldRow(title: "Password", detail: "Enter the current password to update your saved login.") {
                        SecureField("Password", text: $password).textContentType(.password)
                    }
                    Button {
                        Task {
                            guard account != nil || provider != "Jellyfin" else { return }
                            _ = await store.authenticate(id: accountID, serverURL: serverURL,
                                username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, router: router, provider: selectedProvider)
                            password = ""
                        }
                    } label: {
                        TVSettingsRowLabel(title: account?.requiresLogin == true ? "Sign In" : (account == nil ? (addingServer ? "Add Server & Profile" : "Add Profile") : "Update Login"),
                                           detail: "Validate and save this account’s login on the Apple TV.")
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (password.isEmpty && selectedProvider != .emby))
                }
                if account == nil {
                    TVSettingsFooter("Signing in saves this profile and its server together. Saved servers are available in Manage Servers and when adding another profile.")
                }
                } else {
                    TVSettingsFooter("\(provider) connections are coming soon.")
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
                if let error = store.error { Text(error).foregroundStyle(.red).font(.system(size: 21)) }
                if let message { Text(message).font(.system(size: 21)) }
                if store.busy { ProgressView() }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .disabled(store.busy)
        .onAppear {
            username = account?.username ?? ""
            serverURL = account.flatMap { ServerRegistry.shared.entry(with: $0.serverID)?.url } ?? (addingServer ? "" : ServerRegistry.shared.activeServerUrl)
            pinIsSet = accountID.map { store.hasPIN($0) } ?? false
            store.error = nil
        }
        .onDisappear { password = ""; pin = ""; confirmation = "" }
        .onExitCommand { if !store.busy { dismiss() } }
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
            Text(account.username).font(.system(size: 42, weight: .bold))
            SecureField("Four-digit PIN", text: $pin).frame(width: 480)
            Button("Unlock") { onPIN(pin); pin = "" }
                .buttonStyle(TVSettingsPaneRowStyle()).frame(width: 480)
            if let error = store.error { Text(error).font(.system(size: 22)) }
            Button("Cancel") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onExitCommand { dismiss() }
        .onDisappear { pin = "" }
    }
}
#endif
