#if !os(tvOS)
import SwiftUI

/// Download preferences: Wi-Fi-only, requested quality, series-monitoring
/// retention defaults, and storage usage. Backed by the `DownloadSettings`
/// singleton (local `UserDefaults`, same pattern as `PlayerSettings`).
struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadSettings.shared
    private var manager: DownloadManager { DownloadManager.shared }
    @State private var showDeleteAllConfirm = false

    /// Versions the default can prefer; each download matches them per item.
    private static let defaultVersions = [
        DownloadVersionPreference(height: 1080, hdr: nil),
        DownloadVersionPreference(height: 720, hdr: nil),
    ]

    private var formats: [DownloadFormat] {
        let available = manager.availableFormats
        return available.isEmpty ? [.original] : available
    }

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "Downloads",
                subtitle: "Offline quality, cleanup, and storage preferences.",
                systemImage: "arrow.down.circle.fill"
            )
            .settingsPageHeaderRow()

            Section {
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnly)
                    .tint(.vividAccent)
                Picker("Quality", selection: $settings.defaultChoiceTag) {
                    Text("Original · Best").tag(DownloadFormat.original.rawValue)
                    ForEach(Self.defaultVersions, id: \.self) { version in
                        Text("Original · \(version.label)").tag(version.tag)
                    }
                    ForEach(formats.filter { $0 != .original }, id: \.self) { format in
                        Text(manager.qualityLabel(format)).tag(format.rawValue)
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                if formats.count > 1 {
                    Text("Original keeps source quality. A version is used where a movie or episode has one. Lower bitrates use less storage; the server prepares the file before download starts. You can choose a different quality for each download.")
                } else {
                    Text("A version is used where a movie or episode has one. " + (MediaServerProvider.active == .emby
                         ? "Smaller downloads need Emby's conversion service and permission for this account."
                         : "Smaller downloads appear when your server allows download transcoding."))
                }
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
        .task {
            // The quality picker is hidden when the cached capability only
            // offers one preset; re-fetch so permission changes show up here
            // without waiting for the next app foreground.
            await manager.refreshCapability()
        }
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
