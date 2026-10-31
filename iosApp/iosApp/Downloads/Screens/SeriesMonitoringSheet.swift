#if os(iOS)
import SwiftUI

extension DownloadScreens {
    /// Create or edit a series' auto-download rules.
    struct MonitoringSheet: View {
        let seriesId: String
        let seriesTitle: String
        let seasons: [Season]

        @State private var rule: MonitoringRule = .everySeason
        @State private var chosenSeasons: Set<Int> = []
        @State private var deletesWatched = DownloadSettings.shared.monitoringDeletesWatchedByDefault
        @State private var limitGB = DownloadSettings.shared.monitoringLimitGBByDefault
        @State private var isSaving = false
        @State private var saveError: String?
        @Environment(\.dismiss) private var dismiss

        private static let bytesPerGB: Int64 = 1_073_741_824

        private var manager: DownloadManager { .shared }

        var body: some View {
            let titleKey: LocalizedStringKey = existing == nil ? "Monitor Series" : "Edit Monitoring"
            NavigationStack {
                Form {
                    Section {
                        Picker("Episodes", selection: $rule) {
                            ForEach(rules, id: \.self) { rule in
                                Text(verbatim: rule.title).tag(rule)
                            }
                        }
                        if rule == .chosenSeasons {
                            ForEach(seasons) { season in
                                Toggle("Season \(String(season.seasonNumber))", isOn: seasonBinding(season.seasonNumber))
                                    .tint(Color.vividAccent)
                            }
                        }
                    } header: {
                        Text("Keep Downloaded")
                    }
                    Section {
                        Toggle("Delete watched episodes", isOn: $deletesWatched)
                            .tint(Color.vividAccent)
                        Picker("Limit", selection: $limitGB) {
                            ForEach(limitChoices, id: \.self) { gigabytes in
                                if gigabytes == 0 {
                                    Text("Unlimited").tag(gigabytes)
                                } else {
                                    Text("\(gigabytes) GB").tag(gigabytes)
                                }
                            }
                        }
                    } header: {
                        Text("Storage")
                    }
                }
                .navigationTitle(titleKey)
                .navigationBarTitleDisplayMode(.inline)
                .vividScrollContentBackgroundHidden()
                .background(Color.clear)
                .toolbar {
                    VividSheetCloseItem { dismiss() }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(!canSave)
                    }
                }
            }
            .vividGlassSheet(startsTall: true)
            .onAppear(perform: loadExisting)
            .alert("Couldn't Save Monitoring", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: saveError ?? "")
            }
        }

        // MARK: Derived

        private var existing: MonitoredSeries? { manager.monitoring(forSeries: seriesId) }

        private var rules: [MonitoringRule] {
            let offered = manager.offeredMonitoringRules
            return offered.isEmpty ? MonitoringRule.allCases : offered
        }

        /// The usual limits, plus the current one when it isn't among them.
        private var limitChoices: [Int] {
            Set([0, 10, 25, 50, 100, limitGB]).sorted()
        }

        private var canSave: Bool {
            !isSaving && !(rule == .chosenSeasons && chosenSeasons.isEmpty)
        }

        private var errorShown: Binding<Bool> {
            Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        }

        private func seasonBinding(_ number: Int) -> Binding<Bool> {
            Binding(
                get: { chosenSeasons.contains(number) },
                set: { isOn in
                    if isOn {
                        chosenSeasons.insert(number)
                    } else {
                        chosenSeasons.remove(number)
                    }
                }
            )
        }

        // MARK: Actions

        private func loadExisting() {
            guard let existing else { return }
            rule = MonitoringRule(rawValue: existing.mode) ?? .everySeason
            chosenSeasons = Set(existing.seasonNumbers ?? [])
            deletesWatched = existing.deleteWatched
            limitGB = Int(existing.maxStorageBytes / Self.bytesPerGB)
        }

        private func save() {
            isSaving = true
            let bytes = Int64(limitGB) * Self.bytesPerGB
            let numbers = rule == .chosenSeasons ? chosenSeasons.sorted() : nil
            let subscription = existing
            Task { @MainActor in
                do {
                    if let subscription {
                        try await manager.changeMonitoring(
                            id: subscription.id,
                            rule: rule,
                            seasonNumbers: numbers,
                            deleteWatched: deletesWatched,
                            maxStorageBytes: bytes,
                            active: true
                        )
                    } else {
                        try await manager.startMonitoring(
                            seriesId: seriesId,
                            seriesTitle: seriesTitle,
                            rule: rule,
                            seasonNumbers: numbers,
                            deleteWatched: deletesWatched,
                            maxStorageBytes: bytes
                        )
                    }
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
                isSaving = false
            }
        }
    }
}
#endif
