#if os(tvOS)
import SwiftUI

/// What Home has saved on this Apple TV, one row per section with a bin to
/// clear it.
struct TVHomeMetadataSettingsPane: View {
    @State private var cache = TVHomeMetadataCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
            TVSettingsSectionHeader("HOME SCREEN")
            TVSettingsFooter("Spotlight and your enabled Home rows are saved on this Apple TV for the current server and profile. Each row keeps up to 20 items; Spotlight keeps up to 10 slides.")
            TVSettingsFooter("New Home data replaces stale items automatically. Use a bin to clear a section’s saved metadata and unused artwork. It caches again the next time Home refreshes.")
            TVSettingsGroup {
                ForEach(cache.statuses) { status in
                    TVHomeMetadataStatusRow(status: status) { cache.clear(status.id) }
                }
            }
            if let error = cache.storageError { TVSettingsFooter(error) }
        }
        .onAppear { cache.activate() }
    }
}

private struct TVHomeMetadataStatusRow: View {
    let status: TVHomeMetadataCache.Status
    let clear: () -> Void

    var body: some View {
        HStack(spacing: TVSettingsLayout.scaled(20)) {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(6)) {
                Text(status.title)
                    .font(.tvSettings(26, weight: .medium))
                Text(status.updatedAt == nil ? "Not cached" : "\(status.count) items saved")
                    .font(.tvSettings(19))
                    .foregroundStyle(Color.vividSecondaryText)
                if let date = status.updatedAt {
                    Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.tvSettings(17))
                        .foregroundStyle(Color.vividSecondaryText)
                }
            }
            Spacer(minLength: TVSettingsLayout.scaled(20))
            Button(action: clear) {
                Image(systemName: "trash")
                    .font(.tvSettings(25))
                    .frame(width: TVSettingsLayout.scaled(56), height: TVSettingsLayout.scaled(52))
            }
            .buttonStyle(TVMetadataBinStyle())
            .focusEffectDisabled()
            .accessibilityLabel("Clear \(status.title) cache")
        }
        .padding(.horizontal, TVSettingsLayout.scaled(24))
        .padding(.vertical, TVSettingsLayout.scaled(16))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.leading, TVSettingsLayout.scaled(24))
        }
    }
}

/// The bin: white when focused, a faint fill otherwise.
private struct TVMetadataBinStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BinBody(configuration: configuration)
    }

    private struct BinBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12))
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : Color.white.opacity(0.1), in: shape)
                .overlay { shape.strokeBorder(focused ? Color.white : .white.opacity(0.2), lineWidth: 2) }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
        }
    }
}
#endif
