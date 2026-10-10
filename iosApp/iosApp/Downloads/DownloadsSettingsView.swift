#if !os(tvOS)
import SwiftUI

/// Download preferences: Wi-Fi-only, series-monitoring retention defaults,
/// and storage usage. Version and quality are chosen on each download. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showDeleteAllConfirm = false

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "Downloads",
                subtitle: "Wi-Fi, cleanup, and storage preferences.",
                systemImage: "arrow.down.circle.fill"
            )
            .settingsPageHeaderRow()

            Section {
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnly)
                    .tint(.vividAccent)
            } header: {
                Text("Downloads")
            } footer: {
                Text("You choose the version and quality each time you download.")
            }


            Section("Series Monitoring Defaults") {
                Toggle("Delete watched episodes", isOn: $settings.defaultDeleteWatched)
                    .tint(.vividAccent)
                Stepper(
                    settings.defaultMaxStorageGB == 0
                        ? "Storage limit: Unlimited"
                        : "Storage limit: \(settings.defaultMaxStorageGB) GB",
                    value: $settings.defaultMaxStorageGB,
                    in: 0...1000,
                    step: 5
                )
            }


            Section {
                Toggle("Keep watched downloads", isOn: $settings.keepWatchedDownloads)
                    .tint(.vividAccent)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("When off, the Downloads tab suggests freeing up space by removing items you've finished watching.")
            }


            Section("Storage") {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(DownloadFormatting.bytes(manager.totalBytesUsed))
                        .foregroundColor(.vividSecondaryText)
                }
                if !manager.records.isEmpty {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Text("Remove All Downloads")
                    }
                }
            }

        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .settingsListChrome()
        .vividToolbarColorSchemeDark()
        .confirmationDialog(
            "Remove all downloaded files?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                manager.deleteDownloads(ids: manager.records.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
