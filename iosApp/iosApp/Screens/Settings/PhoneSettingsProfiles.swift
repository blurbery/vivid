#if os(iOS)
import SwiftUI

/// The top of Settings on iPhone and iPad: the signed-in profile as a large
/// row that opens its account page, then Profiles, which opens the list of
/// saved profiles with the others' pictures stacked beside it, then Add
/// Profile. Placed in one List section.
struct PhoneSettingsProfileRows: View {
    let openEditor: (String?) -> Void
    @State private var store = TVSavedAccountStore.shared

    var body: some View {
        if let current = store.accounts.first(where: store.isCurrent) {
            Button { openEditor(current.id) } label: { currentCard(current) }
                .disabled(store.busy)
        }
        if !store.otherAccounts.isEmpty {
            NavigationLink { PhoneSettingsProfilesPage() } label: { profilesRow }
                .disabled(store.busy)
        }
        if store.canAddAccount {
            Button { openEditor(nil) } label: {
                PhoneAddProfileRowLabel(iconColumn: Self.iconColumn, spacing: Self.iconSpacing)
            }
            .disabled(store.busy)
        }
    }

    /// Every row's picture sits in a column as wide as the signed-in
    /// profile's, so the text in all three starts on one line.
    static let iconColumn: CGFloat = 64
    static let iconSpacing: CGFloat = 16

    private func currentCard(_ account: TVSavedAccount) -> some View {
        HStack(spacing: Self.iconSpacing) {
            SavedAccountAvatar(account: account, size: Self.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                Text(account.roleAndServerLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(Self.accountPageSummary(for: account))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var profilesRow: some View {
        HStack(spacing: Self.iconSpacing) {
            SavedAccountAvatarStack(accounts: store.otherAccounts, size: 28)
                .frame(width: Self.iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Profiles").font(.body.weight(.medium))
                Text(TVSavedAccount.namesSummary(store.otherAccounts))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// What the signed-in profile's page holds.
    static func accountPageSummary(for account: TVSavedAccount) -> String {
        MediaServerProvider.forServerID(account.serverID) == .silo
            ? String(localized: "PIN, household and sign out")
            : String(localized: "PIN and sign out")
    }
}

/// Add Profile as a Settings row: a plus in the icon tile.
struct PhoneAddProfileRowLabel: View {
    /// The width of the picture column in the rows around it, so the text
    /// lines up with theirs.
    var iconColumn: CGFloat = 44
    var spacing: CGFloat = 14

    var body: some View {
        HStack(spacing: spacing) {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            // The same tile and symbol size as the Settings category icons.
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.06), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .frame(width: iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Profile").font(.body.weight(.medium))
                Text("Sign in to another server")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Keeps the saved profiles current while Settings shows them: the signed-in
/// profile's details (its role included) once, and other devices' changes
/// through iCloud every ten seconds.
struct PhoneSavedProfilesSync: ViewModifier {
    /// Off where another view already keeps the profiles current, such as the
    /// iPhone Duo's side strip.
    var isActive = true
    @State private var store = TVSavedAccountStore.shared
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                guard isActive else { return }
                await CurrentProfileStore.shared.refresh(force: true)
                await store.captureCurrent()
            }
            .task(id: isActive && scenePhase == .active) {
                guard isActive, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await VividCloudAccountSync.shared.synchronize(router: router)
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
    }
}

/// Every saved profile as a row, the signed-in one ticked. Tapping another
/// switches to it (after its PIN, if it has one); the signed-in profile and
/// signed-out ones open their account page. Edit rearranges them.
struct PhoneSettingsProfilesPage: View {
    @State private var store = TVSavedAccountStore.shared
    @State private var editor: PhoneSavedProfilesScreen.EditorTarget?
    @State private var pinAccount: TVSavedAccount?
    @State private var pin = ""
    @State private var pinError: String?
    @State private var editMode: EditMode = .inactive
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            SettingsPageHeader(title: "Profiles",
                               subtitle: "Switch between the profiles saved on this device, or tap Edit to arrange them.",
                               systemImage: "person.2.fill")
                .settingsPageHeaderRow()
            Section {
                ForEach(store.accounts) { account in
                    Button { open(account) } label: { row(account) }
                        .disabled(store.busy)
                }
                .onMove(perform: move)
                if store.canAddAccount {
                    Button { editor = .init(accountID: nil) } label: { PhoneAddProfileRowLabel() }
                        .disabled(store.busy)
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        .toolbar {
            if store.accounts.count > 1 { EditButton() }
        }
        // Paused while rows are being arranged, as on Apple TV.
        .modifier(PhoneSavedProfilesSync(isActive: !editMode.isEditing))
        .environment(\.editMode, $editMode)
        .navigationDestination(item: $editor) { target in
            PhoneSavedProfilesScreen.AccountEditor(accountID: target.accountID)
        }
        .alert("Profile", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: $pinAccount) { account in pinSheet(account) }
    }

    private func row(_ account: TVSavedAccount) -> some View {
        HStack(spacing: 14) {
            SavedAccountAvatar(account: account, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(account.requiresLogin
                     ? String(localized: "Signed out · \(account.serverLabel)")
                     : account.roleAndServerLabel)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if store.isCurrent(account) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .accessibilityLabel("Current profile")
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func open(_ account: TVSavedAccount) {
        guard !store.busy else { return }
        if store.needsLogin(account) || store.isCurrent(account) {
            editor = .init(accountID: account.id)
        } else if store.hasPIN(account.id) {
            pin = ""
            pinError = nil
            pinAccount = account
        } else {
            Task { await store.select(account, router: router) }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = store.accounts.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        _ = store.saveAccountOrder(ids)
    }

    private func pinSheet(_ account: TVSavedAccount) -> some View {
        NavigationStack {
            Form {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                if let pinError {
                    Text(pinError).foregroundStyle(.red)
                }
                Button("Unlock") { unlock(account) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle(account.displayName)
            .toolbar {
                VividSheetCloseItem {
                    pinAccount = nil
                    pin = ""
                }
            }
        }
        .vividGlassSheet()
    }

    private func unlock(_ account: TVSavedAccount) {
        if store.unlock(account.id, pin: pin) {
            pinAccount = nil
            pin = ""
            Task { await store.select(account, router: router) }
        } else {
            pinError = store.error ?? String(localized: "Incorrect PIN")
            pin = ""
        }
    }
}
#endif
