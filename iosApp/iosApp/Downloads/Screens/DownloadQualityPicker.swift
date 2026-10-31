#if os(iOS)
import SwiftUI

/// A selectable row with a tick, used by the version pages.
struct DownloadChoiceRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    init(title: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.vividCaption)
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.vividOnSurface)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quality rules

extension DownloadScreens {
    /// What the server offers, or Original alone when it offers nothing.
    @MainActor
    static func offeredQualities() -> [DownloadFormat] {
        let offered = DownloadManager.shared.offeredQualities
        return offered.isEmpty ? [.original] : offered
    }

    /// The qualities a version of this height can be made in. Auto (nil)
    /// keeps everything; a 4K version only makes 4K copies.
    @MainActor
    static func qualities(forVersionHeight height: Int?) -> [DownloadFormat] {
        let manager = DownloadManager.shared
        return DownloadVersionPreference.formats(
            offeredQualities(),
            versionHeight: height,
            maxHeight: { manager.tallestOutput(of: $0) }
        )
    }

    /// The quality a download will actually use: the stored one when the
    /// version allows it, else the best smaller one it can make, else
    /// Original.
    static func qualityUsed(stored: String, among qualities: [DownloadFormat]) -> DownloadFormat {
        if let format = DownloadFormat(rawValue: stored), qualities.contains(format) { return format }
        if stored == DownloadFormat.original.rawValue { return .original }
        return qualities.first { $0 != .original } ?? .original
    }

    /// Emby picks the source itself for a smaller copy when the server says
    /// versions can't be converted, so the version choice is set aside.
    @MainActor
    static func isEmbyConversion(storedQuality: String) -> Bool {
        MediaServerProvider.active == .emby
            && storedQuality != DownloadFormat.original.rawValue
            && DownloadManager.shared.capability?.versionTranscodes == false
    }

    static var cantShrinkNote: String {
        String(localized: "This version can't be made smaller on this server. Choose another version for a smaller download.")
    }

    static var originalOnlyNote: String {
        String(localized: "Downloads use original quality. Smaller qualities appear when the server allows download transcoding.")
    }

    /// "About 2.3 GB per hour of video." for a smaller preset.
    static func sizeNote(for format: DownloadFormat) -> String? {
        guard format != .original,
              let bytes = StreamedTranscodeDownload.estimatedBytes(format: format, durationSeconds: 3600) else {
            return nil
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "About \(size) per hour of video.")
    }

    /// The footer under the quality menu.
    static func qualityFooter(for format: DownloadFormat, versionHeight: Int?, scopeLine: String?) -> String {
        let parts: [String?] = [
            scopeLine,
            sizeNote(for: format),
            String(localized: "Lower bitrates make a smaller copy of the chosen version. The server prepares it first, which can take longer. Sizes are estimates."),
            (versionHeight ?? 0) >= 2160
                ? String(localized: "A 4K version only makes 4K copies. Choose a smaller version for a smaller resolution.")
                : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Rows and the quality menu

extension DownloadScreens {
    /// An icon row with a title, a detail and a chevron.
    struct OptionRow: View {
        let title: LocalizedStringKey
        let detail: String
        let symbol: String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                    Text(verbatim: detail)
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .padding(.vertical, 4)
        }
    }

    /// The Quality picker every download sheet shares. It keeps its choice
    /// to one the version can make.
    struct QualityMenu: View {
        @Binding var selection: String
        let versionHeight: Int?

        private var manager: DownloadManager { .shared }

        var body: some View {
            Picker(selection: $selection) {
                ForEach(DownloadScreens.qualities(forVersionHeight: versionHeight), id: \.self) { format in
                    Text(verbatim: manager.qualityTitle(for: format))
                        .tag(format.rawValue)
                }
            } label: {
                Label("Quality", systemImage: "slider.horizontal.3")
            }
            .pickerStyle(.menu)
            .onAppear(perform: keepUsable)
            .onChange(of: manager.offeredQualities) { keepUsable() }
            .onChange(of: versionHeight) { keepUsable() }
        }

        private func keepUsable() {
            let used = DownloadScreens.qualityUsed(
                stored: selection,
                among: DownloadScreens.qualities(forVersionHeight: versionHeight)
            )
            if used.rawValue != selection { selection = used.rawValue }
        }
    }
}
#endif
