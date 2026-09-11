#if os(tvOS)
import SwiftUI

struct TVTMDbSettingsView: View {
    @State private var store = TVTMDbStore.shared
    @State private var credential = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 20) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 62, height: 62)
                        .background(Color(red: 0.12, green: 0.13, blue: 0.15),
                                    in: RoundedRectangle(cornerRadius: 15.5))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Trailers")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Configure your personal TMDB API to show trailers for your media.")
                            .font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 18)
                TVSettingsSectionHeader("TMDB CONNECTION")
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: busy ? "Connecting…" : (store.isConfigured ? "Connected" : "Not configured"))
                    if let message { TVSettingsFooter(message).padding(.horizontal, 24) }
                    TVSettingsFieldRow(title: "Personal API key", detail: "You can also use your API Read Access Token.") {
                        SecureField("API key or read access token", text: $credential)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(busy)
                    }
                    Button {
                        guard !busy else { return }
                        let candidate = credential.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !candidate.isEmpty else {
                            message = "Enter your API key, finish editing, then choose Save Connection."
                            return
                        }
                        busy = true; message = "Validating your key with TMDB…"
                        // Keep an explicit save alive if tvOS presents another screen.
                        // Capture the submitted value before any view/focus changes.
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                try await store.connect(candidate)
                                credential = ""
                                message = "Connected. TMDB trailers are enabled."
                            } catch is CancellationError {
                                message = "Connection interrupted. Please try saving again."
                            } catch { message = error.localizedDescription }
                        }
                    } label: { TVSettingsRowLabel(title: busy ? "Connecting…" : "Save Connection") }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    if store.isConfigured {
                        Button {
                            do { try store.disconnect(); credential = ""; message = "Disconnected. Trailers are hidden; More Like This still uses your library." }
                            catch { message = error.localizedDescription }
                        } label: { TVSettingsRowLabel(title: "Disconnect") }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .disabled(busy)
                    }
                }
                TVSettingsFooter("More Like This works without a key, using genres, studios and networks from your server library. Trailers require a TMDB connection and open in the YouTube app, which must be installed on your Apple TV.")
                TVSettingsFooter("Your key is saved in this Apple TV’s Keychain and sent only to TMDB. Get a personal key from your account’s API settings at themoviedb.org. Non-commercial use requires TMDB attribution.")
                TVSettingsSectionHeader("ABOUT TMDB")
                TVTMDbAttribution()
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsBackdrop())
        // SecureField uses a system editing presentation on tvOS. Its lifecycle
        // must not clear the draft or cancel an explicit save. The draft is
        // view-local and is cleared after a successful save or disconnection.
    }
}

struct TVTMDbAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("TMDbAttributionLogo").resizable().scaledToFit()
                .frame(width: 140, height: 54).accessibilityLabel("TMDB")
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.system(size: 19)).foregroundStyle(.secondary)
            Text("themoviedb.org").font(.system(size: 19)).foregroundStyle(.secondary)
        }.padding(24)
    }
}
#endif
