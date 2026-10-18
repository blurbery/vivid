#if os(tvOS)
import SwiftUI

struct TVTMDbSettingsView: View {
    @State private var store = TVTMDbStore.shared
    @State private var credential = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                HStack(spacing: TVSettingsLayout.scaled(20)) {
                    Image(systemName: "film.stack")
                        .font(.tvSettings(27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: TVSettingsLayout.scaled(62), height: TVSettingsLayout.scaled(62))
                        .background(TVSettingsPalette.iconFill,
                                    in: RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(15.5)))
                    VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(7)) {
                        Text("TMDb")
                            .font(.tvSettings(40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Trailers, TMDB ratings, collections and Studios & Networks work without a key. You can add your own TMDB key instead.")
                            .font(.tvSettings(20)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.bottom, TVSettingsLayout.scaled(18))
                TVSettingsSectionHeader("TMDB CONNECTION")
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: busy ? "Connecting…" : (store.usesOwnKey ? "Your key" : store.isConfigured ? "Built in" : "Not available"), showsConnectedDot: store.isConfigured && !busy)
                    if let message { TVSettingsFooter(message).padding(.horizontal, TVSettingsLayout.scaled(24)) }
                    TVSettingsFieldRow(title: "Your own API key (optional)", detail: "You can also use your API Read Access Token.") {
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
                                message = "Connected. TMDB requests now use your own key."
                            } catch is CancellationError {
                                message = "Connection interrupted. Please try saving again."
                            } catch { message = error.localizedDescription }
                        }
                    } label: { TVSettingsRowLabel(title: busy ? "Connecting…" : "Save Connection") }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    if store.usesOwnKey {
                        Button {
                            do { try store.disconnect(); credential = ""; message = "Removed. Vivid's built-in TMDB access is used again." }
                            catch { message = error.localizedDescription }
                        } label: { TVSettingsRowLabel(title: "Remove Your Key") }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .disabled(busy)
                    }
                }
                TVSettingsFooter("More Like This uses genres, studios and networks from your server library. Trailers, the TMDB rating on movie and series pages, collections and Studios & Networks use Vivid’s built-in TMDB access, or your own key if you add one. Trailers open in the YouTube app, which must be installed on your Apple TV.")
                TVSettingsFooter("Without a key of your own, TMDB lookups go through Vivid’s TMDB relay (tmdb.vividapp.co). A key you add is saved in Keychain, syncs through Vivid’s encrypted iCloud vault for the matching server account and profile, and is used only with TMDB. Get a key at themoviedb.org. TMDB attribution is required.")
                TVSettingsSectionHeader("ABOUT TMDB")
                TVTMDbAttribution()
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.top, TVSettingsLayout.scaled(48)).padding(.bottom, TVSettingsLayout.scaled(64))
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
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(16)) {
            Image("TMDbAttributionLogo").resizable().scaledToFit()
                .frame(width: TVSettingsLayout.scaled(140), height: TVSettingsLayout.scaled(54)).accessibilityLabel("TMDB")
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.tvSettings(19)).foregroundStyle(.secondary)
            Text("themoviedb.org").font(.tvSettings(19)).foregroundStyle(.secondary)
        }.padding(TVSettingsLayout.scaled(24))
    }
}
#endif
