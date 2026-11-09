#if os(tvOS)
import SwiftUI

/// The top of Settings: the signed-in profile as a large card that opens its
/// account page, then Profiles, which opens the list of saved profiles with
/// the others' pictures stacked beside it, then Add Profile.
struct TVSettingsProfileSection: View {
    @State private var store = TVSavedAccountStore.shared
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TVSettingsGroup {
            if let current = store.accounts.first(where: store.isCurrent) {
                NavigationLink(value: TVAccountRoute.editor(current.id)) { currentCard(current) }
                    .buttonStyle(TVSettingsView.RailRowStyle())
            }
            if !store.otherAccounts.isEmpty {
                NavigationLink(value: TVAccountRoute.profiles) { profilesRow }
                    .buttonStyle(TVSettingsView.RailRowStyle())
            }
            if store.canAddAccount {
                NavigationLink(value: TVAccountRoute.editor(nil)) {
                    TVAddProfileRowLabel(iconColumn: Self.iconColumn, spacing: Self.iconSpacing)
                }
                .buttonStyle(TVSettingsView.RailRowStyle())
            }
        }
        // Refreshes the signed-in profile's saved details, its role
        // included, as the profile cards did.
        .task {
            await CurrentProfileStore.shared.refresh(force: true)
            await store.captureCurrent()
        }
        // Picks up profiles added or changed on another device while
        // Settings is open, as the profile cards did.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !store.isArrangingProfiles {
                    await VividCloudAccountSync.shared.synchronize(router: router)
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    /// Every row's picture sits in a column as wide as the signed-in
    /// profile's, so the text in all three starts on one line.
    static let iconColumn = TVSettingsLayout.scaled(92)
    static let iconSpacing = TVSettingsLayout.scaled(22)

    private func currentCard(_ account: TVSavedAccount) -> some View {
        HStack(spacing: Self.iconSpacing) {
            SavedAccountAvatar(account: account, size: Self.iconColumn)
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(4)) {
                Text(account.displayName)
                    .font(.tvSettings(34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(account.roleAndServerLabel)
                    .font(.tvSettings(21, weight: .medium))
                    .opacity(0.8)
                    .lineLimit(1)
                Text(Self.accountPageSummary(for: account))
                    .font(.tvSettings(18))
                    .opacity(0.6)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.tvSettings(20, weight: .semibold))
                .opacity(0.5)
        }
        .padding(.vertical, TVSettingsLayout.scaled(6))
        .accessibilityElement(children: .combine)
    }

    private var profilesRow: some View {
        HStack(spacing: Self.iconSpacing) {
            SavedAccountAvatarStack(accounts: store.otherAccounts, size: TVSettingsLayout.scaled(40))
                .frame(width: Self.iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(2)) {
                Text("Profiles")
                    .font(.tvSettings(25, weight: .medium))
                Text(TVSavedAccount.namesSummary(store.otherAccounts))
                    .font(.tvSettings(19))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.tvSettings(17, weight: .semibold))
                .opacity(0.5)
        }
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
struct TVAddProfileRowLabel: View {
    /// The width of the picture column in the rows around it, so the text
    /// lines up with theirs.
    var iconColumn = TVSettingsLayout.scaled(48)
    var spacing = TVSettingsLayout.scaled(16)

    var body: some View {
        HStack(spacing: spacing) {
            let shape = RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous)
            // The same tile and symbol size as the Settings category icons.
            Image(systemName: "plus")
                .font(.tvSettings(22, weight: .medium))
                .frame(width: TVSettingsLayout.scaled(48), height: TVSettingsLayout.scaled(48))
                .background(TVSettingsPalette.iconFill, in: shape)
                .overlay(shape.strokeBorder(TVSettingsPalette.separator, lineWidth: 1))
                .frame(width: iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(2)) {
                Text("Add Profile")
                    .font(.tvSettings(25, weight: .medium))
                Text("Sign in to another server")
                    .font(.tvSettings(19))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.tvSettings(17, weight: .semibold))
                .opacity(0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every saved profile as a row, the signed-in one ticked. Selecting another
/// switches to it (after its PIN, if it has one); the signed-in profile and
/// signed-out ones open their account page. Press and hold to arrange.
struct TVSettingsProfilesPage: View {
    @State private var store = TVSavedAccountStore.shared
    @State private var pinAccount: TVSavedAccount?
    @State private var movingID: String?
    @State private var draftOrder: [String] = []
    @FocusState private var focused: String?
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            SettingsBackdrop()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                    TVSettingsPageHeader(title: "Profiles",
                                         subtitle: "Switch between the profiles saved on this Apple TV. Press and hold one to arrange them.")
                        .icon(.symbol("person.2.fill"))
                    TVSettingsGroup {
                        ForEach(displayedAccounts) { account in
                            row(account)
                        }
                        if store.canAddAccount {
                            NavigationLink(value: TVAccountRoute.editor(nil)) {
                                TVAddProfileRowLabel(iconColumn: TVSettingsLayout.scaled(56))
                            }
                                .buttonStyle(TVSettingsView.RailRowStyle())
                                .disabled(movingID != nil)
                        }
                    }
                    .padding(.top, TVSettingsLayout.scaled(18))
                }
                .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.bottom, TVSettingsLayout.scaled(64))
            }
            .contentMargins(.horizontal, TVSettingsLayout.scaled(24), for: .scrollContent)
            .scrollClipDisabled()
            .frame(maxWidth: TVSettingsLayout.pageWidth, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaPadding(.top, 48)
            .safeAreaPadding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
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
        .onDisappear { cancelArrangement() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelArrangement() }
        }
        .onChange(of: movingID) { _, id in store.isArrangingProfiles = id != nil }
        // Picks up profiles changed on another device while this page is
        // open, except while one is being moved.
        .task(id: scenePhase == .active && movingID == nil) {
            guard scenePhase == .active, movingID == nil else { return }
            while !Task.isCancelled {
                await VividCloudAccountSync.shared.synchronize(router: router)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    @ViewBuilder
    private func row(_ account: TVSavedAccount) -> some View {
        if account.id == movingID {
            // The one focus target while arranging: Up and Down move it,
            // Select drops it and saves the order, and Menu puts it back.
            Button { finishArrangement() } label: { rowLabel(account, isMoving: true) }
                .buttonStyle(TVSettingsView.RailRowStyle())
                .focused($focused, equals: account.id)
                .onAppear { focused = account.id }
                .onMoveCommand { direction in
                    switch direction {
                    case .up: moveDraft(account.id, by: -1)
                    case .down: moveDraft(account.id, by: 1)
                    default: break
                    }
                }
                .onExitCommand { cancelArrangement() }
                .accessibilityLabel("Move \(account.displayName). Move up or down, then press centre to drop and save.")
        } else {
            Button { open(account) } label: { rowLabel(account, isMoving: false) }
                .buttonStyle(TVSettingsView.RailRowStyle())
                .focused($focused, equals: account.id)
                .disabled(movingID != nil)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginArrangement(account.id) })
                .accessibilityAction(named: "Arrange Profiles") { beginArrangement(account.id) }
        }
    }

    private func rowLabel(_ account: TVSavedAccount, isMoving: Bool) -> some View {
        HStack(spacing: TVSettingsLayout.scaled(16)) {
            SavedAccountAvatar(account: account, size: TVSettingsLayout.scaled(56))
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(2)) {
                Text(account.displayName)
                    .font(.tvSettings(25, weight: .medium))
                    .lineLimit(1)
                Text(account.requiresLogin
                     ? String(localized: "Signed out · \(account.serverLabel)")
                     : account.roleAndServerLabel)
                    .font(.tvSettings(19))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isMoving {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.tvSettings(20, weight: .semibold))
            } else if store.isCurrent(account) {
                Image(systemName: "checkmark")
                    .font(.tvSettings(20, weight: .bold))
                    .accessibilityLabel("Current profile")
            } else {
                Image(systemName: "chevron.right")
                    .font(.tvSettings(17, weight: .semibold))
                    .opacity(0.5)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func open(_ account: TVSavedAccount) {
        guard !store.busy else { return }
        if store.needsLogin(account) || store.isCurrent(account) {
            router.path.append(TVAccountRoute.editor(account.id))
        } else if store.hasPIN(account.id) {
            pinAccount = account
        } else {
            Task { await store.select(account, router: router) }
        }
    }

    // MARK: Arranging

    private var displayedAccounts: [TVSavedAccount] {
        guard movingID != nil else { return store.accounts }
        let ids = VividCloudPreferencePolicy.ordered(store.accounts.map(\.id), preferred: draftOrder)
        let byID = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private func beginArrangement(_ id: String) {
        guard !store.busy, store.accounts.count > 1 else { return }
        draftOrder = store.accounts.map(\.id)
        movingID = id
    }

    private func finishArrangement() {
        _ = store.saveAccountOrder(draftOrder)
        cancelArrangement()
    }

    private func cancelArrangement() {
        let returnID = movingID
        // Cleared here as well as on change, since a page that is closing
        // may not see the change.
        store.isArrangingProfiles = false
        movingID = nil
        draftOrder = []
        if let returnID { focused = returnID }
    }

    private func moveDraft(_ id: String, by offset: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            draftOrder = VividCloudPreferencePolicy.moving(draftOrder, id: id, by: offset)
        }
    }
}
#endif
