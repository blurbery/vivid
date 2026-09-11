#if os(iOS) || os(tvOS)
import SwiftUI

struct OpenSubtitlesSettingsView: View {
    @State private var store = OpenSubtitlesStore.shared
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("OpenSubtitles").font(.system(size: 40, weight: .bold, design: .rounded))
                TVSettingsFooter("Find and download subtitles from the player’s subtitle menu.")
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: status, showsConnectedDot: store.isConnected && !busy)
                    TVSettingsFieldRow(title: "Personal API key", detail: "Get your key at opensubtitles.com/en/consumers.") { keyField }
                    Button(action: connect) { TVSettingsRowLabel(title: busy ? "Connecting…" : "Save Connection") }
                        .buttonStyle(TVSettingsPaneRowStyle()).disabled(busy || key.isEmpty)
                    if store.isConnected {
                        Button(action: disconnect) { TVSettingsRowLabel(title: "Disconnect") }.buttonStyle(TVSettingsPaneRowStyle())
                    }
                }
                if let message { TVSettingsFooter(message) }
                TVSettingsFooter(footer)
            }.frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
                .padding(48).frame(maxWidth: .infinity)
        }.background(SettingsBackdrop()).task { store.reload() }
        #else
        List {
            SettingsPageHeader(title: "OpenSubtitles", subtitle: "Find and download subtitles from the player’s subtitle menu.", systemImage: "captions.bubble")
                .settingsPageHeaderRow()
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        if store.isConnected && !busy { Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true) }
                        Text(status)
                    }
                }
                keyField
                Button(busy ? "Connecting…" : "Save Connection", action: connect).disabled(busy || key.isEmpty)
                Link("Get your API key", destination: URL(string: "https://www.opensubtitles.com/en/consumers")!)
                if store.isConnected { Button("Disconnect", role: .destructive, action: disconnect) }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text(footer) }
        }.settingsListChrome().navigationTitle("").task { store.reload() }
        #endif
    }
    private var status: String { busy ? "Connecting…" : store.isConnected ? "Connected" : "Not connected" }
    private var footer: String { "Your key is stored in Keychain and syncs through Vivid’s encrypted iCloud account vault. Downloads use OpenSubtitles’ quota and are temporary for the current playback. Nothing is uploaded to your media server." }
    private var keyField: some View {
        SecureField("OpenSubtitles API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
    }
    private func connect() {
        busy = true; message = nil
        let candidate = key
        Task { @MainActor in
            defer { busy = false }
            do { try await store.connect(candidate); key = "" }
            catch { message = error.localizedDescription }
        }
    }
    private func disconnect() {
        do { try store.disconnect(); key = ""; message = nil }
        catch { message = error.localizedDescription }
    }
}

struct OpenSubtitlesSearchView: View {
    @State private var store = OpenSubtitlesStore.shared
    let viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var language = "en"
    @State private var results: [OpenSubtitleResult] = []
    @State private var message: String?
    @State private var busy = false
    @State private var context: OpenSubtitlePlaybackContext?
    @State private var connectionRevision: UUID?
    @State private var operation: Task<Void, Never>?
    @FocusState private var focusedField: SearchField?
    private enum SearchField: Hashable { case title, language }

    var body: some View {
        NavigationStack {
            List {
                if !store.isConnected { Text(OpenSubtitlesError.notConfigured.localizedDescription).foregroundStyle(.secondary) }
                Section {
                    TextField("Movie or series title", text: $query).focused($focusedField, equals: .title)
                    TextField("Language code, e.g. en", text: $language).focused($focusedField, equals: .language).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "Working…" : "Search", action: search).disabled(busy || !store.isConnected || query.isEmpty || language.isEmpty)
                } footer: { Text("Choose a matching release. Each download uses your OpenSubtitles quota.") }
                if let message { Text(message).foregroundStyle(.secondary) }
                Section {
                    ForEach(results) { result in
                        Button { download(result) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.name).lineLimit(2)
                                Text(result.language + (result.hearingImpaired ? " · Hearing impaired" : "") + " · Download & use")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(busy)
                    }
                }
            }
            .navigationTitle("OpenSubtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { focusedField = nil; dismiss() } } }
            .task { query = viewModel.openSubtitleContext?.query.title ?? ""; OpenSubtitlesStore.shared.reload() }
            .onDisappear { focusedField = nil; operation?.cancel() }
            #if os(tvOS)
            .onExitCommand { dismiss() }
            #endif
        }
    }
    private func search() {
        focusedField = nil
        store.reload()
        guard store.isConnected else { message = OpenSubtitlesError.notConfigured.localizedDescription; return }
        guard let current = viewModel.openSubtitleContext else { message = OpenSubtitlesError.context.localizedDescription; return }
        let requested = OpenSubtitleQuery(title: query, type: current.query.type, season: current.query.season, episode: current.query.episode)
        let requestedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        busy = true; message = nil; results = []; context = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let found = try await OpenSubtitlesStore.shared.search(requested, language: requestedLanguage)
                try Task.checkCancellation()
                guard current == viewModel.openSubtitleContext else { throw OpenSubtitlesError.context }
                results = found; context = current; connectionRevision = OpenSubtitlesStore.shared.revision
                if found.isEmpty { message = "No subtitles found. Try another title or language." }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private func download(_ result: OpenSubtitleResult) {
        guard let context, let connectionRevision, context == viewModel.openSubtitleContext else {
            message = OpenSubtitlesError.context.localizedDescription; return
        }
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await OpenSubtitlesStore.shared.download(result, expectedRevision: connectionRevision)
                try Task.checkCancellation()
                try viewModel.useOpenSubtitle(result, data: data, expected: context)
                dismiss()
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}
#endif
