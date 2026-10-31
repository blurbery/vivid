#if os(iOS)
import SwiftUI

/// Pieces the download controls and pages share: byte text, the device's
/// storage, the pre-download size estimate, and the small parts several
/// screens draw the same way.
enum DownloadScreens {
    /// A byte count in the system's file style, or a dash for nothing.
    static func byteText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "S2 · E5", "E5" or the series title when neither number is known.
    /// Not localised.
    static func episodeTag(season: Int?, episode: Int?, fallback: String?) -> String? {
        let parts = [season.map { "S\($0)" }, episode.map { "E\($0)" }].compactMap { $0 }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }

    /// The type label shared with the rest of the app ("Series").
    static var seriesLabel: String {
        String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
    }

    /// "Specials" or "Season 2" for a downloaded season.
    static func seasonName(_ season: DownloadedSeason) -> String {
        season.holdsSpecials ? String(localized: "Specials") : String(localized: "Season \(String(season.seasonKey))")
    }

    /// Plays a downloaded movie or episode from where it was left, when it's
    /// on the device.
    @MainActor
    static func play(_ record: DownloadRecord, router: AppRouter) {
        guard record.isPlayableOffline else { return }
        let position = DownloadManager.shared.savedProgress(for: record.leafMediaItemId)?.position
        router.presentOfflinePlayer(
            downloadId: record.id,
            contentId: record.leafMediaItemId,
            resumePosition: position
        )
    }

    /// The first poster saved on disk among these records, in their order.
    @MainActor
    static func firstPosterFile(in records: [DownloadRecord]) -> URL? {
        for record in records {
            if let url = DownloadManager.shared.posterFile(for: record),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Device storage and size estimate

extension DownloadScreens {
    /// The volume holding the home folder, 0 where the system doesn't say.
    struct DeviceStorage {
        let total: Int64
        let available: Int64

        static func read() -> DeviceStorage {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? home.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ])
            return DeviceStorage(
                total: Int64(values?.volumeTotalCapacity ?? 0),
                available: values?.volumeAvailableCapacityForImportantUsage ?? 0
            )
        }
    }

    /// How big a download will be: one file's size, or the spread of sizes
    /// when the server picks the file.
    struct SizeEstimate {
        let smallest: Int64
        let largest: Int64

        var isRange: Bool { smallest != largest }

        var label: String {
            isRange ? byteText(smallest) + "\u{2013}" + byteText(largest) : byteText(largest)
        }

        /// Over 5 GB, in the formatter's decimal units.
        var isLarge: Bool { largest > 5_000_000_000 }

        /// The exact size of the chosen file, or the range of every version
        /// with a size for Auto.
        static func make(versions: [FileVersion], fileId: Int?) -> SizeEstimate? {
            if let fileId {
                guard let size = versions.first(where: { $0.fileId == fileId })?.fileSize, size > 0 else {
                    return nil
                }
                return SizeEstimate(smallest: size, largest: size)
            }
            let sizes = versions.compactMap(\.fileSize).filter { $0 > 0 }
            guard let smallest = sizes.min(), let largest = sizes.max() else { return nil }
            return SizeEstimate(smallest: smallest, largest: largest)
        }

        /// A warning for a big download or one that won't fit. Uses the
        /// largest size, since Auto commits to whatever the server picks.
        /// An available figure of 0 means the lookup failed.
        func warning(available: Int64) -> String? {
            let size = DownloadScreens.byteText(largest)
            if available > 0, largest > available {
                let free = DownloadScreens.byteText(available)
                return isRange
                    ? String(localized: "This download may be up to \(size), but only \(free) is free on this device.")
                    : String(localized: "This download is \(size), but only \(free) is free on this device.")
            }
            guard isLarge else { return nil }
            return isRange
                ? String(localized: "This download may be up to \(size).")
                : String(localized: "This download is \(size).")
        }
    }
}

// MARK: - Shared parts

extension DownloadScreens {
    /// A highlight that circles a download's progress. It always moves.
    struct ActivityArc: View {
        let diameter: CGFloat
        var lineWidth: CGFloat = 2.5

        private static let period = 1.15

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let turn = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period
                Circle()
                    .trim(from: 0.02, to: 0.24)
                    .stroke(
                        AngularGradient(
                            colors: [Color.white.opacity(0.18), Color.white, Color.white.opacity(0.18)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(turn * 360 - 90))
            }
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The round tick used to pick rows.
    struct SelectionCircle: View {
        let isSelected: Bool

        var body: some View {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.vividOnSurface : Color.clear)
                Circle()
                    .stroke(isSelected ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.35), lineWidth: 1.5)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black)
                }
            }
            .frame(width: 22, height: 22)
        }
    }

    /// The download arrow struck through, for accounts that can't download.
    struct CrossedOutGlyph: View {
        let size: CGFloat

        var body: some View {
            ZStack {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.35))
                Image(systemName: "xmark")
                    .font(.system(size: size * 1.05, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .accessibilityHidden(true)
        }
    }

    /// Explains why the download controls are crossed out.
    struct UnavailableAlert: ViewModifier {
        @Binding var isPresented: Bool

        func body(content: Content) -> some View {
            content.alert("Downloads Unavailable", isPresented: $isPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Downloads aren't enabled for this account. The server's admin can allow them.")
            }
        }
    }

    /// A poster at 2:3: the ThumbHash, with the saved artwork over it once it
    /// loads. Nothing shows over the hash while loading or if it fails.
    struct PosterTile: View {
        let thumbhash: String?
        let file: URL?
        var width: CGFloat = 40
        var cornerRadius: CGFloat = 7

        var body: some View {
            ZStack {
                ThumbhashImage(thumbhash: thumbhash)
                if let file {
                    AsyncImage(url: file) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        }
                    }
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// "SERIES" or "MOVIE" beside a title.
    struct KindChip: View {
        let isSeries: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            Text((isSeries ? DownloadScreens.seriesLabel : String(localized: "Movie")).uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Color.vividSecondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(shape.fill(Color.vividChromeRestingFill))
                .overlay(shape.stroke(Color.vividChromeRestingBorder, lineWidth: 1))
        }
    }

    /// "Downloaded · ..." under a title on the offline pages.
    struct AvailabilityChip: View {
        let text: String

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: text)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Color.vividOnSurface)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.vividChromeSelectedFill))
            .overlay(Capsule().stroke(Color.vividChromeSelectedBorder, lineWidth: 1))
        }
    }

    /// One downloaded episode in an open series card or on the offline
    /// series page. Tapping plays it; its menu deletes it straight away.
    struct EpisodeRow: View {
        let record: DownloadRecord
        let isWatched: Bool
        let onPlay: () -> Void
        let onDelete: () -> Void

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 11) {
                    ZStack {
                        ThumbhashImage(thumbhash: record.posterThumbhash)
                            .frame(width: 54, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                    .opacity(isWatched ? 0.5 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                            .opacity(isWatched ? 0.55 : 1)
                        Text(verbatim: detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if isWatched {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface.opacity(0.5))
                    } else {
                        Image(systemName: "play.circle")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color.vividOnSurface)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }

        private var title: String {
            let name = record.title ?? record.contentId
            guard let number = record.episodeNumber else { return name }
            return String(
                localized: "E\(String(number)) · \(name)",
                comment: "Episode number abbreviation and episode title, e.g. E4 · Pilot"
            )
        }

        private var detail: String {
            let size = DownloadScreens.byteText(record.fileSize)
            return isWatched ? String(localized: "Watched · \(size)") : size
        }
    }
}
#endif
