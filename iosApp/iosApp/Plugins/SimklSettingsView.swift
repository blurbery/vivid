import SwiftUI

struct SimklSettingsView: View {
    @State private var store = SimklSyncStore.shared
    @State private var message: String?
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                header
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: connectionStatus, showsConnectedDot: store.isConnected)
                    if store.isConnected && store.isSyncing { syncProgress.padding(TVSettingsLayout.scaled(24)) }
                    if let prompt = store.signIn {
                        signInCode(prompt).padding(TVSettingsLayout.scaled(24))
                        Button { store.cancelSignIn() } label: { TVSettingsRowLabel(title: "Cancel") }
                            .buttonStyle(TVSettingsPaneRowStyle())
                    } else if !store.isConnected {
                        Button { store.beginSignIn() } label: {
                            TVSettingsRowLabel(title: "Sign in with Simkl", detail: "Approve Vivid on your phone with a short code.")
                        }.buttonStyle(TVSettingsPaneRowStyle())
                    } else {
                        Button { store.syncNow() } label: { TVSettingsRowLabel(title: "Sync now") }
                            .buttonStyle(TVSettingsPaneRowStyle()).disabled(store.isSyncing)
                        Button { disconnect() } label: { TVSettingsRowLabel(title: "Disconnect") }
                            .buttonStyle(TVSettingsPaneRowStyle())
                    }
                }
                if store.isConnected { TVSettingsFooter(store.status) }
                if let notice = message ?? store.signInMessage { TVSettingsFooter(notice) }
                TVSettingsFooter(privacy)
            }.frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.vertical, TVSettingsLayout.scaled(48)).frame(maxWidth: .infinity)
        }.background(SettingsBackdrop()).task { store.reload() }
        #else
        List {
            header
                .settingsPageHeaderRow()
                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        if store.isConnected { Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true) }
                        Text(connectionStatus)
                    }
                }
                if store.isConnected && store.isSyncing { syncProgress.padding(.vertical, 6) }
                if let prompt = store.signIn {
                    signInCode(prompt).padding(.vertical, 6)
                    Link("Open Simkl", destination: prompt.approvalURL)
                    Button("Cancel", role: .cancel) { store.cancelSignIn() }
                } else if !store.isConnected {
                    Button("Sign in with Simkl") { store.beginSignIn() }
                } else {
                    Button("Sync now") { store.syncNow() }.disabled(store.isSyncing)
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
                if store.isConnected { Text(store.status).font(.footnote).foregroundStyle(.secondary) }
                if let notice = message ?? store.signInMessage { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text(privacy) }
        }.settingsListChrome().listSectionSpacing(8).navigationTitle("").task { store.reload() }
            // The code is ready: take the person straight to Simkl to approve it.
            .onChange(of: store.signIn?.userCode) { _, code in
                if code != nil, let url = store.signIn?.approvalURL { openURL(url) }
            }
        #endif
    }

    @ViewBuilder
    private var syncProgress: some View {
        if let progress = store.syncProgress {
            VStack(alignment: .leading, spacing: 8) {
                Text(progress.description).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .accessibilityLabel(progress.description)
            }
        }
    }

    private func signInCode(_ prompt: SimklSyncStore.SignInPrompt) -> some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: TVSettingsLayout.scaled(32)) {
            QRCodeView(content: prompt.approvalURL.absoluteString, size: TVSettingsLayout.scaled(220))
                .padding(TVSettingsLayout.scaled(12))
                .background(.white, in: RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                Text("Scan the code with your phone, or go to \(prompt.verificationURL.host ?? "simkl.com")\(prompt.verificationURL.path) and enter:")
                    .font(.tvSettings(26))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: prompt.userCode)
                    .font(.tvSettings(56, weight: .bold, design: .monospaced))
                Text("Vivid connects once you approve it on Simkl.")
                    .font(.tvSettings(24))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve Vivid on Simkl. If Simkl asks for a code, enter:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: prompt.userCode)
                .font(.system(.title, design: .monospaced, weight: .bold))
                .textSelection(.enabled)
            Text("Vivid connects once you approve it on Simkl.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #endif
    }

    private var connectionStatus: String {
        if store.isConnected { return String(localized: "Connected") }
        if store.signIn != nil { return String(localized: "Waiting for approval") }
        return String(localized: "Not connected")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Simkl")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Connect your Simkl account.")
                #if os(tvOS)
                .font(.tvSettings(40, weight: .bold, design: .rounded))
                #else
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                #endif
                .fixedSize(horizontal: false, vertical: true)
            Text("Send completed watches to Simkl and keep its Plan to Watch list in step with your watchlist. Watchlist matches include titles on your active server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Current watches and resume points stay untouched.", systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacy: String { String(localized: "Each device signs in to Simkl separately. The sign-in stays in this device’s Keychain for the matching server account and profile and isn’t synced through iCloud. Sync shares media identifiers, watched dates and watchlist changes, never server login details. Disconnecting keeps your Simkl history and lists.") }

    private func disconnect() {
        do { try store.disconnect(); message = nil }
        catch { message = error.localizedDescription }
    }
}
