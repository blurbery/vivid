#if os(iOS)
import SwiftUI

/// Settings > General > Downloads: Wi-Fi only, monitoring defaults,
/// cleanup and storage.
struct DownloadsSettingsView: View {
    @State private var showsRemoveAll = false

    init() {}

    private var manager: DownloadManager { .shared }

    var body: some View {
        @Bindable var settings = DownloadSettings.shared
        Form {
            SettingsPageHeader(
                title: "Downloads",
                subtitle: "Wi-Fi, cleanup, and storage preferences.",
                systemImage: "arrow.down.circle.fill"
            )
            .settingsPageHeaderRow()
            Section {
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnlyTransfers)
                    .tint(Color.vividAccent)
            } header: {
                Text("Downloads")
            } footer: {
                Text("You choose the version and quality each time you download.")
            }
            Section {
                Toggle("Delete watched episodes", isOn: $settings.monitoringDeletesWatchedByDefault)
                    .tint(Color.vividAccent)
                Stepper(value: $settings.monitoringLimitGBByDefault, in: 0...1000, step: 5) {
                    if settings.monitoringLimitGBByDefault == 0 {
                        Text("Storage limit: Unlimited")
                    } else {
                        Text("Storage limit: \(settings.monitoringLimitGBByDefault) GB")
                    }
                }
            } header: {
                Text("Series Monitoring Defaults")
            }
            Section {
                Toggle("Keep watched downloads", isOn: $settings.keepsWatchedDownloads)
                    .tint(Color.vividAccent)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("When off, the Downloads tab suggests freeing up space by removing items you've finished watching.")
            }
            Section {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(verbatim: DownloadScreens.byteText(manager.bytesOnDisk))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                if !manager.records.isEmpty {
                    Button("Remove All Downloads", role: .destructive) {
                        showsRemoveAll = true
                    }
                }
            } header: {
                Text("Storage")
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        .confirmationDialog("Remove all downloaded files?", isPresented: $showsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                manager.remove(recordIds: manager.records.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
