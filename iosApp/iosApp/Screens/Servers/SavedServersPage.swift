import SwiftUI

/// The saved servers on this device: switch between them, add one, or
/// remove one with its profiles.
struct ServerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var pendingRemoval: ServerEntry?
    @State private var removalError: String?

    #if os(tvOS)
    private enum FocusTarget: Hashable {
        case server(String)
        case remove(String)
        case addServer
    }

    @FocusState private var focus: FocusTarget?
    #endif

    init() {}

    private var entries: [ServerEntry] { registry.sortedEntries }

    private func isActive(_ entry: ServerEntry) -> Bool {
        entry.id == registry.activeServerId
    }

    // MARK: Actions

    private func switchTo(_ entry: ServerEntry) {
        if isActive(entry) {
            #if os(iOS)
            refreshSignInState()
            #endif
            return
        }
        Task {
            guard await ServerRegistry.shared.switchTo(serverId: entry.id, resolveDestinationProfile: true) else { return }
            await MainActor.run {
                TVSavedAccountStore.shared.noteChosenServer()
                refreshSignInState()
            }
        }
    }

    /// Sends the app to whatever the new server still needs: setup, sign
    /// in, a profile, or nothing.
    private func refreshSignInState() {
        router.popToRoot()
        PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
        let auth = AuthService.shared
        if !auth.hasServer {
            router.authState = .needsServerSetup
        } else if !auth.isLoggedIn {
            router.authState = .needsLogin
        } else if !auth.hasProfile {
            router.authState = .needsProfile
        } else {
            router.authState = .authenticated
        }
    }

    private func remove(_ entry: ServerEntry) {
        removalError = nil
        Task {
            let store = TVSavedAccountStore.shared
            if !(await store.deleteServer(entry.id, router: router)) {
                removalError = store.error ?? String(localized: "Couldn’t remove the saved server. Try again.")
            }
            pendingRemoval = nil
        }
    }

    #if os(iOS)
    // MARK: iPhone and iPad

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Manage Servers",
                subtitle: "Manage saved media servers for this device.",
                systemImage: "server.rack",
                tint: .teal
            )
            .settingsPageHeaderRow()

            Section {
                ForEach(entries, id: \.id) { entry in
                    row(entry)
                }
            } header: {
                Text("Saved servers")
                    .foregroundStyle(Color.vividSecondaryText)
            } footer: {
                if let removalError {
                    Text(verbatim: removalError)
                }
            }

            Section {
                NavigationLink {
                    PhoneProviderSelectionView(router: router, addsServer: true)
                        .navigationTitle("Add Server")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .foregroundStyle(Color.vividOnSurface)
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Remove this server?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { entry in
            Button("Remove", role: .destructive) { remove(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("The saved server \(entry.displayName) and all its profiles will be removed from your Vivid devices through iCloud. Accounts and media on the server are not deleted.")
        }
    }

    private func row(_ entry: ServerEntry) -> some View {
        Button {
            switchTo(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive(entry) ? "checkmark.circle.fill" : "server.rack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.vividOnSurface)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.displayName)
                        .font(.vividSubheadline)
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    Text(verbatim: entry.url)
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingRemoval = entry
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
    #else
    // MARK: Apple TV

    var body: some View {
        ZStack {
            page
                .disabled(pendingRemoval != nil)
            if let entry = pendingRemoval {
                TVSettingsConfirmationOverlay(
                    title: String(localized: "Remove this server?"),
                    message: removalMessage(entry),
                    confirmTitle: String(localized: "Remove"),
                    cancel: { dismissConfirmation(for: entry) },
                    confirm: { remove(entry) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .background(SettingsBackdrop())
        .animation(.easeOut(duration: 0.12), value: pendingRemoval?.id)
    }

    private func dismissConfirmation(for entry: ServerEntry) {
        pendingRemoval = nil
        Task { @MainActor in
            await Task.yield()
            focus = .remove(entry.id)
        }
    }

    private func removalMessage(_ entry: ServerEntry) -> String {
        String(localized: "The saved server \(entry.displayName) and all its profiles will be removed from your Vivid devices through iCloud. Accounts and media on the server are not deleted.")
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        TVSettingsLayout.scaled(value)
    }

    private var page: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: scaled(8)) {
                heading
                TVSettingsSectionHeader("SAVED SERVERS")
                if entries.isEmpty {
                    TVSettingsFooter("No servers have been saved on this Apple TV.")
                } else {
                    TVSettingsGroup {
                        ForEach(entries, id: \.id) { entry in
                            serverRow(entry)
                        }
                    }
                }
                TVSettingsSectionHeader("CONNECTIONS")
                TVSettingsGroup {
                    NavigationLink {
                        TVProviderSelectionView(addingServer: true)
                    } label: {
                        HStack(spacing: scaled(16)) {
                            Image(systemName: "plus")
                                .font(.tvSettings(22, weight: .semibold))
                                .frame(width: scaled(28))
                            TVSettingsRowLabel(title: "Add Server")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.tvSettings(18, weight: .semibold))
                                .opacity(0.55)
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focus, equals: .addServer)
                }
                TVSettingsFooter("Select the trash icon to remove a saved server and its profiles from your Vivid devices.")
                if let removalError {
                    TVSettingsFooter(removalError)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, scaled(24))
            .padding(.vertical, scaled(48))
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focus, entries.first.map { FocusTarget.server($0.id) } ?? .addServer)
    }

    private var heading: some View {
        HStack(spacing: scaled(20)) {
            Image(systemName: "server.rack")
                .font(.tvSettings(27, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: scaled(62), height: scaled(62))
                .background(
                    Color(red: 0.12, green: 0.13, blue: 0.15),
                    in: RoundedRectangle(cornerRadius: scaled(15.5), style: .continuous)
                )
            VStack(alignment: .leading, spacing: scaled(7)) {
                Text("Manage Servers")
                    .font(.tvSettings(40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Manage the servers shared by your saved profiles.")
                    .font(.tvSettings(20))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .padding(.horizontal, scaled(24))
        .padding(.bottom, scaled(18))
    }

    private func serverRow(_ entry: ServerEntry) -> some View {
        let active = isActive(entry)
        return HStack(spacing: 0) {
            Button {
                switchTo(entry)
            } label: {
                rowLabel(entry, isActive: active)
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focus, equals: .server(entry.id))
            .accessibilityHint(
                active
                    ? Text("Current server. Server names are managed by the server administrator")
                    : Text("Switch to this server. Server names are managed by the server administrator")
            )

            Button {
                pendingRemoval = entry
            } label: {
                Image(systemName: "trash")
                    .font(.tvSettings(24, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: scaled(49))
            }
            .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
            .frame(width: scaled(92))
            .focused($focus, equals: .remove(entry.id))
            .accessibilityLabel(Text("Remove \(entry.displayName)"))
        }
    }

    private func rowLabel(_ entry: ServerEntry, isActive: Bool) -> some View {
        HStack(spacing: scaled(18)) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                .font(.tvSettings(24, weight: .medium))
                .frame(width: scaled(34))
            VStack(alignment: .leading, spacing: scaled(4)) {
                Text(verbatim: entry.displayName)
                    .font(.tvSettings(26, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: entry.url)
                    .font(.tvSettings(19))
                    .opacity(0.62)
                    .lineLimit(1)
            }
            Spacer(minLength: scaled(16))
            if isActive {
                Text("Active")
                    .font(.tvSettings(19, weight: .semibold))
                    .opacity(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? Text("Active") : Text("Saved"))
    }
    #endif
}
