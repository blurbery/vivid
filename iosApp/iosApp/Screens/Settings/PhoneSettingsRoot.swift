import SwiftUI

/// Settings on iPhone and iPad: profiles, then a row for each settings
/// page. Apple TV uses `TVSettingsView`, so this draws nothing there.
struct SettingsView: View {
    #if os(iOS)
    @State private var model = SettingsViewModel()
    @State private var unsentReports = 0
    @State private var editor: PhoneSavedProfilesScreen.EditorTarget?
    @Environment(\.duoSideStrip) private var duoSideStrip
    #endif

    init() {}

    var body: some View {
        #if os(iOS)
        overview
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
extension SettingsView {
    private var overview: some View {
        List {
            Text("Settings")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .modifier(CentredOnPad())
                .settingsPageHeaderRow()
            if duoSideStrip == nil {
                Section {
                    PhoneSavedProfilesScreen.AccountCards(layout: .settings, openEditor: openEditor)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                } header: { PhoneSettingsSectionHeader("Profiles").modifier(CentredOnPad()) }
            }
            Section {
                destinationRows
            } header: { PhoneSettingsSectionHeader("Settings") }
            VividCopyrightFooter()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .settingsListChrome()
        .navigationTitle("")
        .environment(\.colorScheme, .dark)
        .overlay { duoProfileStrip }
        .navigationDestination(item: $editor) { target in
            PhoneSavedProfilesScreen.AccountEditor(accountID: target.accountID)
        }
        .task { await model.load() }
        .task { await countUnsentReports() }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            Task { await countUnsentReports() }
        }
    }

    @ViewBuilder
    private var destinationRows: some View {
        OverviewRow(title: "General", subtitle: Text("App and navigation"), icon: .symbol("gearshape")) {
            GeneralPage()
        }
        OverviewRow(title: "Playback", subtitle: Text("Quality, audio and episodes"), icon: .symbol("play.rectangle")) {
            PlaybackPage(model: model)
        }
        OverviewRow(title: "Subtitles", subtitle: Text("Language and appearance"), icon: .symbol("captions.bubble")) {
            SubtitlesPage(model: model)
        }
        OverviewRow(title: "Servers", subtitle: Text("Connection and version"), icon: .symbol("server.rack")) {
            ServersPage(model: model)
        }
        OverviewRow(title: "Plugins", subtitle: Text("Trailers and watched history"), icon: .symbol("puzzlepiece.extension")) {
            PluginsSettingsView()
        }
        OverviewRow(title: "Seerr", subtitle: Text("Media requests"), icon: .asset("SeerrSettingsIcon")) {
            SeerrPage()
        }
        OverviewRow(title: "Metadata", subtitle: Text("Home cache and storage"), icon: .symbol("internaldrive")) {
            MetadataPage()
        }
        OverviewRow(title: "Diagnostics",
                    subtitle: unsentReports == 0 ? Text("Crash and hang reports") : Text("\(unsentReports) new"),
                    icon: .symbol("stethoscope")) {
            DiagnosticsSettingsView()
        }
        OverviewRow(title: "About", subtitle: Text("App details and contact"), icon: .asset("AboutInfoIcon")) {
            AboutSettingsView()
        }
    }

    /// Beside the Duo's side status bar, the profiles sit in a glass strip
    /// there instead of in the list.
    @ViewBuilder
    private var duoProfileStrip: some View {
        if let strip = duoSideStrip {
            PhoneSavedProfilesScreen.AccountCards(layout: .strip, openEditor: openEditor)
                .frame(width: 2 * PhoneDuo.ControlCorner.centreFromEdge)
                .padding(.top, strip.controlsTop + 44 + 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: strip.edge == .trailing ? .topTrailing : .topLeading)
                .ignoresSafeArea()
        }
    }

    private func openEditor(_ accountID: String?) {
        editor = PhoneSavedProfilesScreen.EditorTarget(accountID: accountID)
    }

    private func countUnsentReports() async {
        unsentReports = await Task.detached(priority: .utility) {
            AppHealthSendState.unsent(in: AppHealthStore.shared.reports()).count
        }.value
    }
}

/// On iPad, centres the overview's heading and Profiles label in the
/// settings column. iPhone keeps them at the leading edge.
private struct CentredOnPad: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

/// One overview row: an icon tile, the page name and what it covers.
private struct OverviewRow<Destination: View>: View {
    enum Icon {
        case symbol(String)
        case asset(String)
    }

    let title: LocalizedStringKey
    let subtitle: Text
    let icon: Icon
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    subtitle.font(.footnote).foregroundStyle(.white.opacity(0.7))
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

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name).font(.body.weight(.medium))
            case .asset(let name):
                Image(name).renderingMode(.template).resizable().scaledToFit().padding(9)
            }
        }
        .frame(width: 42, height: 42)
        .background(.white.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Servers

extension SettingsView {
    /// The connected server for this profile, which can be renamed for the
    /// profile, and the way to the full server list.
    struct ServersPage: View {
        let model: SettingsViewModel
        @State private var accounts = TVSavedAccountStore.shared
        @State private var renaming = false
        @State private var nameDraft = ""
        @State private var renameFailed = false

        private var account: TVSavedAccount? { accounts.activeAccount }

        private var serverName: String {
            if let name = account?.serverName, !name.isEmpty { return name }
            return model.serverDisplayName
        }

        /// What shows when no name is set.
        private var defaultName: String { account?.defaultServerLabel ?? model.serverDisplayName }

        private var hasCustomName: Bool { !(account?.serverName ?? "").isEmpty }

        var body: some View {
            List {
                SettingsPageHeader(title: "Servers", subtitle: "The media server this device is connected to.",
                                   systemImage: "server.rack")
                    .settingsPageHeaderRow()
                Section {
                    Button(action: startRename) {
                        LabeledContent("Server") {
                            HStack(spacing: 6) {
                                Text(serverName)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .disabled(account == nil)
                    .accessibilityHint("Rename this server for this profile")
                    LabeledContent("Address", value: model.serverAddress)
                    NavigationLink("Manage Servers") { ServerListView() }
                        .foregroundStyle(.white)
                } header: {
                    PhoneSettingsSectionHeader("Connection")
                } footer: {
                    if renameFailed {
                        Text("Couldn’t rename the server. Try again.")
                    } else if account != nil {
                        Text("Tap Server to rename it for this profile.")
                    }
                }
            }
            .settingsListChrome()
            .navigationTitle("")
            .alert("Rename Server", isPresented: $renaming) {
                TextField(defaultName, text: $nameDraft)
                Button("Save") { rename(to: nameDraft) }
                if hasCustomName {
                    Button("Use Server Name") { rename(to: nil) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This name shows for this profile only, under its profile picture and here. Leave it blank to show “\(defaultName)”.")
            }
        }

        private func startRename() {
            renameFailed = false
            nameDraft = account?.serverName ?? ""
            renaming = true
        }

        private func rename(to name: String?) {
            guard let account, accounts.renameServer(for: account.id, to: name) else {
                renameFailed = true
                return
            }
        }
    }
}
#endif
