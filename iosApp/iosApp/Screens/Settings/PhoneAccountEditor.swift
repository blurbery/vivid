#if os(iOS)
import SwiftUI

extension PhoneSavedProfilesScreen {
    /// Adds a profile, or edits one: its sign-in, Silo household profiles,
    /// PIN, sign out and removal.
    struct AccountEditor: View {
        let accountID: String?

        @State private var store = TVSavedAccountStore.shared
        @State private var codeSignIn = CodeSignIn()
        @State private var household = SiloHouseholdSearch()
        @State private var provider: MediaServerProvider = .silo
        @State private var address = ""
        @State private var username = ""
        @State private var password = ""
        @State private var newPIN = ""
        @State private var confirmPIN = ""
        @State private var message: String?
        @State private var asksToDelete = false
        @State private var isPrepared = false
        @Environment(AppRouter.self) private var router
        @Environment(\.dismiss) private var dismiss

        private static let providers: [MediaServerProvider] = [.silo, .emby, .jellyfin]

        private var account: TVSavedAccount? {
            accountID.flatMap { id in store.accounts.first { $0.id == id } }
        }

        private var isNew: Bool { accountID == nil }

        private var isActive: Bool {
            accountID != nil && store.activeID == accountID && !store.showsSelector && AuthService.shared.isLoggedIn
        }

        private var registeredAddress: String? {
            account.flatMap { ServerRegistry.shared.entry(with: $0.serverID)?.url }
        }

        /// The address a sign-in goes to.
        private var serverURL: String { registeredAddress ?? address }

        private var savedServers: [ServerEntry] {
            ServerRegistry.shared.sortedEntries.filter { MediaServerProvider.forServerID($0.id) == provider }
        }

        var body: some View {
            List {
                header.settingsPageHeaderRow()
                if isNew { serverSection }
                accountSection
                if codeSignIn.isActive { codeSection }
                if isActive, provider == .silo, let account { householdSection(account) }
                if isActive, let accountID { pinSection(accountID) }
                if let accountID { removalSection(accountID) }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                VividCopyrightFooter()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            .settingsListChrome()
            .navigationTitle("")
            .onAppear(perform: prepare)
            .onDisappear { codeSignIn.cancel() }
            .onChange(of: address) {
                if codeSignIn.isActive && codeSignIn.canCancel { codeSignIn.cancel() }
            }
            .confirmationDialog("Delete Profile?", isPresented: $asksToDelete, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \(account?.displayName ?? "") and its saved connection from Vivid on your iCloud devices? Other profiles and the actual server account and library won’t be deleted.")
            }
            .sheet(item: householdPINProfile) { profile in
                if let account {
                    PINEntryView(profile: profile, onCancel: { household.cancelPIN(for: account) }) { pin in
                        Task { await household.add(profile, pin: pin, for: account) }
                    }
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled()
                }
            }
        }

        @ViewBuilder
        private var header: some View {
            if let account {
                SettingsPageHeader(title: Text(account.displayName), subtitle: Text("Account details and access on this device."),
                                   systemImage: "person.crop.circle")
            } else {
                SettingsPageHeader(title: "Add Profile", subtitle: "Account details and access on this device.",
                                   systemImage: "person.crop.circle")
            }
        }

        // MARK: Sections

        private var serverSection: some View {
            Section {
                Picker("Server Provider", selection: providerSelection) {
                    ForEach(Self.providers, id: \.self) { Text(verbatim: $0.name).tag($0) }
                }
                if !savedServers.isEmpty {
                    Picker("Saved Server", selection: $address) {
                        Text("Enter an address").tag("")
                        ForEach(savedServers) { Text(verbatim: $0.displayName).tag($0.url) }
                    }
                }
            } header: { PhoneSettingsSectionHeader("Server") }
        }

        private var providerSelection: Binding<MediaServerProvider> {
            Binding(get: { provider }, set: { newValue in
                if codeSignIn.isActive && codeSignIn.canCancel { codeSignIn.cancel() }
                provider = newValue
                if isNew { address = ServerRegistry.shared.address(address, keptFor: newValue) }
            })
        }

        private var accountSection: some View {
            Section {
                if isNew {
                    TextField("Server address", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                } else {
                    LabeledContent("Server", value: registeredAddress ?? address)
                }
                if let profileName = account?.siloProfileName {
                    LabeledContent("Profile", value: profileName)
                    LabeledContent("Username") {
                        TextField("Username", text: $username)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.username)
                    }
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button(submitTitle, action: submit)
                    .disabled(submitDisabled)
                if provider != .silo, !codeSignIn.isActive, let service = CodeSignIn.Service(provider) {
                    Button("Use \(service.title)") { startCodeSignIn(service) }
                        .disabled((isNew && !store.canAddAccount) || store.busy || serverURL.isEmpty)
                }
            } header: { PhoneSettingsSectionHeader("Account") }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        private var submitTitle: LocalizedStringKey {
            if isNew { return "Add Profile" }
            if let account, store.needsLogin(account) { return "Sign In" }
            return "Update Login"
        }

        private var submitDisabled: Bool {
            (isNew && !store.canAddAccount) || store.busy || (provider == .silo && password.isEmpty)
                || username.isEmpty || serverURL.isEmpty
        }

        private var codeSection: some View {
            let service = codeSignIn.service
            return Section {
                if let code = codeSignIn.code {
                    LabeledContent(service.codeTitle) {
                        Text(verbatim: code)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .textSelection(.enabled)
                            .speechSpellsOutCharacters()
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
                    Button(service.getNewTitle) { startCodeSignIn(service) }
                }
                Button("Cancel", role: .cancel) { codeSignIn.cancel() }
                    .disabled(!codeSignIn.canCancel)
            } header: {
                PhoneSettingsSectionHeader(service.title)
            } footer: {
                Text(service.instructions)
            }
        }

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                case .results:
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
                    Button("Search Again") { Task { await household.search(for: account) } }
                case .failed:
                    Button("Try Again") { Task { await household.search(for: account) } }
                }
                if let note = household.message {
                    Text(note).font(.footnote)
                }
            } header: {
                PhoneSettingsSectionHeader("Household")
            } footer: {
                Text("Find the other profiles on this Silo account and add them to this device. Each one gets its own Vivid profile.")
            }
        }

        private var householdPINProfile: Binding<UserProfile?> {
            Binding(get: { household.pinProfile }, set: { household.pinProfile = $0 })
        }

        private func pinSection(_ id: String) -> some View {
            let hasPIN = store.hasPIN(id)
            return Section {
                SecureField("New PIN", text: $newPIN).keyboardType(.numberPad)
                SecureField("Confirm PIN", text: $confirmPIN).keyboardType(.numberPad)
                Button(hasPIN ? "Change PIN" : "Set PIN") { savePIN(id) }
                    .disabled(store.busy)
                if hasPIN {
                    Button("Remove PIN") {
                        message = store.removePIN(id) ? String(localized: "PIN removed") : String(localized: "Couldn’t remove the PIN.")
                    }
                }
            } header: { PhoneSettingsSectionHeader("PIN Protection") }
        }

        private func removalSection(_ id: String) -> some View {
            Section {
                if isActive {
                    Button(role: .destructive) {
                        Task { await store.signOut(router: router) }
                    } label: {
                        Text("Sign Out").frame(maxWidth: .infinity)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                Button(role: .destructive) { asksToDelete = true } label: {
                    Text("Delete Profile").frame(maxWidth: .infinity)
                }
                .disabled(store.busy)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
        }

        // MARK: Actions

        private func prepare() {
            guard !isPrepared else { return }
            isPrepared = true
            if let account {
                provider = MediaServerProvider.forServerID(account.serverID)
                username = account.username
                address = registeredAddress ?? ""
            } else {
                address = ServerRegistry.shared.activeServerUrl
                provider = MediaServerProvider.forServerID(ServerRegistry.shared.activeServerId)
            }
        }

        private func submit() {
            let url = serverURL
            let login = (username: username, password: password)
            Task {
                let signedIn = await store.authenticate(id: accountID, serverURL: url, username: login.username,
                                                        password: login.password, router: router, provider: provider)
                password = ""
                if signedIn { dismiss() } else { message = store.error }
            }
        }

        private func startCodeSignIn(_ service: CodeSignIn.Service) {
            message = nil
            let url = registeredAddress ?? ServerRegistry.shared.normalizedUserAddress(address)
            switch service {
            case .jellyfinQuickConnect:
                codeSignIn.startQuickConnect(serverURL: url) { login in
                    await finishCodeSignIn(service, url: url, username: login.username, quickConnect: login)
                }
            case .embyConnect:
                codeSignIn.startEmbyConnect(serverURL: url) { login in
                    await finishCodeSignIn(service, url: url, username: login.username, embyConnect: login)
                }
            }
        }

        /// Saves an approved code sign-in. Returns the message to show when
        /// it couldn't be saved.
        private func finishCodeSignIn(_ service: CodeSignIn.Service, url: String, username: String,
                                      quickConnect: JellyfinLogin? = nil, embyConnect: EmbyLogin? = nil) async -> String? {
            let signedIn = await store.authenticate(id: accountID, serverURL: url, username: username, password: "",
                                                    router: router, provider: provider,
                                                    quickConnect: quickConnect, embyConnect: embyConnect)
            if signedIn {
                dismiss()
                return nil
            }
            return store.error ?? String(localized: "Couldn’t finish signing in with \(service.title). Please try again.")
        }

        private func savePIN(_ id: String) {
            guard newPIN == confirmPIN else {
                message = String(localized: "The PINs don’t match.")
                return
            }
            if store.setPIN(newPIN, accountID: id) {
                message = String(localized: "PIN saved")
                newPIN = ""
                confirmPIN = ""
            } else {
                message = store.error
            }
        }

        private func delete() {
            guard let accountID else { return }
            Task {
                if await store.deleteAccount(accountID, router: router) { dismiss() }
            }
        }
    }
}
#endif
