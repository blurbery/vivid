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
                TVSettingsFooter("Find and download subtitles from the detail page or player.")
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
            SettingsPageHeader(title: "OpenSubtitles", subtitle: "Find and download subtitles from the detail page or player.", systemImage: "captions.bubble")
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
    private var footer: String { "Your key is stored in Keychain and syncs through Vivid’s encrypted iCloud vault for the matching server account and profile. Downloads use OpenSubtitles’ quota and are temporary for the current playback. Nothing is uploaded to your media server." }
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
    private let currentContext: () -> OpenSubtitlePlaybackContext?
    private let useSubtitle: (OpenSubtitleResult, Data, OpenSubtitlePlaybackContext) throws -> Void

    init(viewModel: PlayerViewModel) {
        currentContext = { viewModel.openSubtitleContext }
        useSubtitle = { try viewModel.useOpenSubtitle($0, data: $1, expected: $2) }
    }

    init(context: @escaping () -> OpenSubtitlePlaybackContext?,
         onUse: @escaping (OpenSubtitleResult, Data, OpenSubtitlePlaybackContext) throws -> Void) {
        currentContext = context
        useSubtitle = onUse
    }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var language = "en"
    @State private var results: [OpenSubtitleResult] = []
    @State private var message: String?
    @State private var busy = false
    @State private var context: OpenSubtitlePlaybackContext?
    @State private var connectionRevision: UUID?
    @State private var successfulParameters: [String: String]?
    @State private var operation: Task<Void, Never>?
    @FocusState private var focusedField: SearchField?
    private enum SearchField: Hashable { case title, language }

    var body: some View {
        NavigationStack {
            List {
                if !store.isConnected {
                    NavigationLink("Connect OpenSubtitles") { OpenSubtitlesSettingsView() }
                }
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
            .task { query = currentContext()?.query.title ?? ""; OpenSubtitlesStore.shared.reload() }
            .onAppear { store.reload() }
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
        guard let current = currentContext() else { message = OpenSubtitlesError.context.localizedDescription; return }
        let requested = OpenSubtitleQuery(title: query, type: current.query.type, season: current.query.season, episode: current.query.episode)
        let requestedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parameters = requested.parameters(language: requestedLanguage)
        if context != current || connectionRevision != store.revision || successfulParameters != parameters {
            results = []; context = nil; successfulParameters = nil
        }
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let found = try await OpenSubtitlesStore.shared.search(requested, language: requestedLanguage)
                try Task.checkCancellation()
                guard current == currentContext() else { throw OpenSubtitlesError.context }
                results = found; context = current; connectionRevision = OpenSubtitlesStore.shared.revision
                successfulParameters = parameters
                if found.isEmpty { message = "No subtitles found. Try another title or language." }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private func download(_ result: OpenSubtitleResult) {
        guard let context, let connectionRevision, context == currentContext() else {
            message = OpenSubtitlesError.context.localizedDescription; return
        }
        busy = true; message = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await OpenSubtitlesStore.shared.download(result, expectedRevision: connectionRevision)
                try Task.checkCancellation()
                store.reload()
                guard store.revision == connectionRevision else { throw OpenSubtitlesError.context }
                try useSubtitle(result, data, context)
                dismiss()
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}
private struct OpenSubtitleDetailContextKey: EnvironmentKey {
    static let defaultValue: OpenSubtitlePlaybackContext? = nil
}

extension EnvironmentValues {
    var openSubtitleDetailContext: OpenSubtitlePlaybackContext? {
        get { self[OpenSubtitleDetailContextKey.self] }
        set { self[OpenSubtitleDetailContextKey.self] = newValue }
    }
}

private struct OpenSubtitleDetailSearch: ViewModifier {
    @Environment(\.openSubtitleDetailContext) private var detailContext
    let fileID: Int?
    @Binding var isPresented: Bool
    private var context: OpenSubtitlePlaybackContext? {
        guard var context = detailContext, let fileID else { return nil }
        context.fileID = fileID
        return context
    }
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            LucidDetailSubtitleMenu(context: context)
        }
    }
}

extension View {
    func openSubtitlesDetailSearch(fileID: Int?, isPresented: Binding<Bool>) -> some View {
        modifier(OpenSubtitleDetailSearch(fileID: fileID, isPresented: isPresented))
    }
}

private struct LucidDetailSubtitleMenu: View {
    let context: OpenSubtitlePlaybackContext?
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [PlayerTrack] = []
    @State private var loading = true
    @State private var message: String?
    @State private var selectedID: Int64?
    @State private var selectionIsAutomatic = true
    private var hasStagedSelection: Bool {
        context.flatMap { OpenSubtitlesStore.shared.stagedLabel(context: $0) } != nil
    }
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Find on OpenSubtitles") {
                        OpenSubtitlesSearchView(context: { context }) { result, data, expected in
                            guard context == expected else { throw OpenSubtitlesError.context }
                            try OpenSubtitlesStore.shared.stage(result, data: data, context: expected)
                            LucidSubtitleInventory.shared.clearChoice(context: expected)
                            selectedID = nil
                            selectionIsAutomatic = false
                        }
                    }
                }
                Section("Embedded Subtitles") {
                    if loading { ProgressView("Reading subtitles…") }
                    else if let message {
                        Text(message).foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }
                    } else {
                        TrackSelectionRow(name: "Auto", attributes: nil, isSelected: selectionIsAutomatic && !hasStagedSelection) {
                            guard let context else { return }
                            LucidSubtitleInventory.shared.clearChoice(context: context)
                            OpenSubtitlesStore.shared.clearStaged(context: context)
                            selectionIsAutomatic = true
                            dismiss()
                        }
                        TrackSelectionRow(name: "Off", attributes: nil, isSelected: !selectionIsAutomatic && selectedID == nil && !hasStagedSelection) { select(nil) }
                        ForEach(LucidSubtitleInventory.ordered(tracks)) { track in
                            TrackSelectionRow(name: track.languageFirstPrimaryLabel,
                                detail: track.languageFirstDetailLabel,
                                attributes: nil, pills: track.attributePillLabels(includeLanguage: track.normalizedLanguageCode == nil),
                                isSelected: selectedID == track.trackId && !hasStagedSelection) { select(track.trackId) }
                        }
                        if tracks.isEmpty { Text("This media file has no embedded subtitles.").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Subtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: "\(context?.contentID ?? ""):\(context?.fileID ?? -1):\(retry)") {
            loading = true; message = nil; tracks = []
            guard let context else { loading = false; message = "Select an episode and file first."; return }
            do {
                tracks = try await LucidSubtitleInventory.shared.read(context: context)
                if let choice = LucidSubtitleInventory.shared.choice(context: context) {
                    selectedID = choice.trackID
                    selectionIsAutomatic = false
                } else {
                    selectedID = nil
                    selectionIsAutomatic = PlayerSettings.shared.preferredSubtitleMode != "off"
                }
            } catch is CancellationError { return }
            catch { message = "Unable to read this file’s embedded subtitles. Try again." }
            loading = false
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
    private func select(_ id: Int64?) {
        guard let context else { return }
        LucidSubtitleInventory.shared.choose(id, context: context)
        selectedID = id
        selectionIsAutomatic = false
        dismiss()
    }
}


#if os(tvOS)
/// A native submenu for the current file. Account setup remains in its own form.
struct OpenSubtitlesMenu: View {
    private let currentContext: () -> OpenSubtitlePlaybackContext?
    private let useSubtitle: (OpenSubtitleResult, Data, OpenSubtitlePlaybackContext) throws -> Void
    @State private var store = OpenSubtitlesStore.shared
    @State private var language = "en"
    @State private var results: [OpenSubtitleResult] = []
    @State private var busy = false
    @State private var message: String?
    @State private var showConnection = false
    @State private var retry = 0
    @State private var generation = UUID()
    @State private var downloadTask: Task<Void, Never>?
    @State private var loadedKey: String?

    init(viewModel: PlayerViewModel) {
        currentContext = { viewModel.openSubtitleContext }
        useSubtitle = { try viewModel.useOpenSubtitle($0, data: $1, expected: $2) }
        _language = State(initialValue: Self.initialLanguage)
    }

    init(context: @escaping () -> OpenSubtitlePlaybackContext?,
         onUse: @escaping (OpenSubtitleResult, Data, OpenSubtitlePlaybackContext) throws -> Void) {
        currentContext = context
        useSubtitle = onUse
        _language = State(initialValue: Self.initialLanguage)
    }

    private static var initialLanguage: String {
        let settings = PlayerSettings.shared
        let preference = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : settings.preferredSubtitleLanguage
        guard let preference, !preference.isEmpty, preference != PlaybackPrefSentinel.none,
              preference != PlaybackPrefSentinel.originalLanguage else { return "en" }
        return preference
    }

    private var searchKey: String {
        "\(currentContext()?.contentID ?? ""):\(currentContext()?.fileID ?? -1):\(currentContext()?.generation ?? 0):\(language):\(store.revision):\(retry)"
    }

    var body: some View {
        Menu("Find on OpenSubtitles") {
            if !store.isConnected {
                Button("Connect OpenSubtitles") { showConnection = true }
            } else {
                Picker("Language", selection: $language) {
                    ForEach(PlaybackLanguageOption.options(for: .playbackSubtitleLanguage, currentValue: language)
                        .filter { $0.code != PlaybackPrefSentinel.originalLanguage }) { option in
                        Text(option.label).tag(option.code)
                    }
                }
                if busy { Text("Working…") }
                else if let message { Text(message) }
                else if results.isEmpty { Text("No matching subtitles") }
                ForEach(results) { result in
                    Button {
                        download(result)
                    } label: {
                        Text(result.name + (result.hearingImpaired ? " · SDH" : ""))
                    }
                    .disabled(busy || loadedKey != searchKey)
                }
                Divider()
                Button("Search Again") { retry += 1 }.disabled(busy)
            }
        }
        .onAppear { store.reload() }
        .task(id: searchKey) {
            downloadTask?.cancel()
            let token = UUID(); generation = token
            results = []; message = nil; loadedKey = nil
            guard store.isConnected, let context = currentContext() else { busy = false; return }
            busy = true
            let key = searchKey
            defer { if generation == token { busy = false } }
            do {
                let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
                let code = Locale(identifier: parts.first ?? "en").language.languageCode?.identifier(.alpha2) ?? language
                let apiLanguage = ([code] + parts.dropFirst()).joined(separator: "-").lowercased()
                let found = try await store.search(context.query, language: apiLanguage)
                try Task.checkCancellation()
                guard currentContext() == context, key == searchKey, generation == token else { return }
                results = found; loadedKey = key
            } catch is CancellationError { }
            catch { if generation == token { message = "Search unavailable. Try again." } }
        }
        .sheet(isPresented: $showConnection) { NavigationStack { OpenSubtitlesSettingsView() } }
        .onDisappear { downloadTask?.cancel() }
    }

    private func download(_ result: OpenSubtitleResult) {
        guard !busy, loadedKey == searchKey, let context = currentContext() else { return }
        let revision = store.revision
        let key = searchKey
        let token = generation
        busy = true
        downloadTask = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                let data = try await store.download(result, expectedRevision: revision)
                try Task.checkCancellation()
                guard context == currentContext(), key == searchKey, generation == token else { return }
                try useSubtitle(result, data, context)
                message = "Subtitle selected"
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }
}
#endif
#endif
