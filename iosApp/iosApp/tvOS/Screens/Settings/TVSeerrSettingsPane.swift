#if os(tvOS)
import SwiftUI

struct TVSeerrSettingsPane: View {
    @State private var store = TVSeerrConnectionStore.shared
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSettingsSectionHeader("CONNECTION")
            TVSettingsGroup {
                TVSettingsFieldRow(title: "Seerr URL", detail: "Your Seerr address, including https:// or http://.") {
                    TextField("https://seerr.example.com", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TVSettingsFieldRow(title: "Username", detail: "Use your email for a local Seerr account, or your imported Jellyfin/Emby username.") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TVSettingsFieldRow(title: "Password", detail: store.isConfigured ? "Leave blank to keep the saved password." : "Saved securely in this Apple TV's Keychain.") {
                    SecureField("Password", text: $password)
                }
                Button {
                    busy = true
                    message = nil
                    Task { @MainActor in
                        do {
                            try await store.connect(url: url, username: username, password: password)
                            password = ""
                            message = "Connected. Available to request is now enabled in Search."
                        } catch { message = error.localizedDescription }
                        busy = false
                    }
                } label: {
                    TVSettingsRowLabel(title: busy ? "Connecting…" : "Save Connection", detail: "Validate this account and enable requests in Search.")
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                if store.isConfigured {
                    Button {
                        do { try store.disconnect(); password = ""; message = "Disconnected. Request results are hidden." }
                        catch { message = error.localizedDescription }
                    } label: { TVSettingsRowLabel(title: "Disconnect", detail: "Remove this Seerr connection from matching accounts and profiles across iCloud devices.") }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
            }
            .disabled(busy)
            if let message { Text(message).font(.system(size: 20)).foregroundStyle(.secondary).padding(.horizontal, 24) }
        }
        .onAppear {
            if let config = store.configuration { url = config.url; username = config.username }
        }
    }
}
#endif
