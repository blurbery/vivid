#if os(tvOS)
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Small copies of library posters, kept on this Apple TV so Who's watching
/// can draw its wall before anyone is signed in and without asking a server.
/// They come from the rows the signed-in profile shows on Home, never from
/// its Continue Watching or Next Up rows, so the wall says nothing about what anyone
/// watched. They stay out of the saved account record and the iCloud vault.
enum TVPosterWallStore {
    private static let writer = Writer()

    /// Counts the times new posters were saved, so a page showing the wall
    /// can load them.
    @MainActor
    @Observable
    final class Revision {
        fileprivate(set) var value = 0
    }

    @MainActor static let revision = Revision()
    /// Posters kept per profile.
    private static let perProfile = 40

    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Vivid/PosterWall/v1", isDirectory: true)
    }

    private static func folder(_ scope: String) -> URL {
        directory.appendingPathComponent(scope, isDirectory: true)
    }

    private static func scope(for account: TVSavedAccount) -> String? {
        guard let profileID = account.profile?.id else { return nil }
        return VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: profileID)
    }

    /// A profile behind a Vivid PIN or a Silo profile PIN adds nothing to
    /// the wall.
    @MainActor
    private static func isLocked(_ account: TVSavedAccount) -> Bool {
        TVSavedAccountStore.shared.hasPIN(account.id) || account.profile?.hasPin == true
    }

    /// Saves posters from the Home rows the signed-in profile shows.
    @MainActor
    static func capture(_ sections: [ResolvedSection], scope: String) {
        guard let account = TVSavedAccountStore.shared.activeAccount,
              Self.scope(for: account) == scope, !isLocked(account) else {
            Task.detached(priority: .utility) { await writer.delete(scope: scope) }
            return
        }
        let history: Set<String> = ["continue_watching", "in_progress", "next_up"]
        let rows = sections
            .filter { !history.contains($0.sectionType.lowercased()) }
            .map { $0.items.filter { $0.type.lowercased() != "episode" && !($0.posterUrl ?? "").isEmpty } }
        let base = MediaServerProvider.active == .silo ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        var seen = Set<String>()
        var posters: [(name: String, url: URL)] = []
        // One from each row in turn, so the wall mixes the rows.
        var depth = 0
        while posters.count < perProfile, rows.contains(where: { $0.count > depth }) {
            for row in rows where row.count > depth && posters.count < perProfile {
                let item = row[depth]
                guard seen.insert(item.contentId).inserted, let raw = item.posterUrl,
                      let url = SiloAPICompatibility.artworkURL(raw, relativeTo: base) else { continue }
                let digest = SHA256.hash(data: Data(item.contentId.utf8))
                posters.append(("\(digest.prefix(10).map { String(format: "%02x", $0) }.joined()).jpg", url))
            }
            depth += 1
        }
        Task.detached(priority: .utility) {
            await writer.save(posters, scope: scope)
        }
    }

    static func delete(for account: TVSavedAccount) async {
        guard let scope = scope(for: account) else { return }
        await writer.delete(scope: scope)
    }

    /// One profile's wall: its own posters and nobody else's, so a child's
    /// profile never shows the posters of a grown-up's library. Empty for a
    /// profile behind a PIN and for one whose Home hasn't loaded on this
    /// Apple TV, which then shows plain tiles.
    @MainActor
    static func posters(for account: TVSavedAccount) async -> TVPosterWallSet {
        guard !isLocked(account), let scope = scope(for: account) else { return .empty }
        let folder = folder(scope)
        let load = Task.detached(priority: .userInitiated) { () -> TVPosterWallSet in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let files = names.filter { $0.hasSuffix(".jpg") }.sorted().map { folder.appendingPathComponent($0) }
            var images: [UIImage] = []
            for file in files {
                // A turn to another profile while this one loads drops it.
                if Task.isCancelled { return .empty }
                if let image = UIImage(contentsOfFile: file.path)?.preparingForDisplay() { images.append(image) }
            }
            return TVPosterWallSet(files: files.map(\.path), images: images)
        }
        return await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
    }

    /// One writer, so a profile's folder changes in one place.
    private actor Writer {
        func save(_ posters: [(name: String, url: URL)], scope: String) async {
            let folder = TVPosterWallStore.folder(scope)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved = false
            for poster in posters {
                let file = folder.appendingPathComponent(poster.name)
                guard !FileManager.default.fileExists(atPath: file.path),
                      let data = try? await VividImagePipeline.shared.data(
                          for: VividImageRequest(url: poster.url, cacheScope: scope)
                      ) else { continue }
                if Self.writePoster(data, to: file) { saved = true }
            }
            let kept = Set(posters.map(\.name))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where !kept.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            if saved {
                await MainActor.run { TVPosterWallStore.revision.value += 1 }
            }
        }

        func delete(scope: String) {
            try? FileManager.default.removeItem(at: TVPosterWallStore.folder(scope))
        }

        /// Saves the poster at the size the wall draws it, as a JPEG. It
        /// is written beside its place and moved in once whole, so a failed
        /// or interrupted write never leaves a broken poster that counts as
        /// saved.
        private static func writePoster(_ data: Data, to file: URL) -> Bool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ]
            let partial = file.appendingPathExtension("partial")
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(
                      partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                  ) else { return false }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination),
                  (try? FileManager.default.moveItem(at: partial, to: file)) != nil else {
                try? FileManager.default.removeItem(at: partial)
                return false
            }
            return true
        }
    }
}

/// The posters one profile's wall draws, decoded and ready.
struct TVPosterWallSet: Equatable {
    static let empty = TVPosterWallSet(files: [], images: [])

    /// The saved files, which tell two sets apart.
    let files: [String]
    let images: [UIImage]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.files == rhs.files }
}

/// Who's watching's background: a tilted wall of the focused profile's
/// posters drifting slowly, alternate columns in opposite directions, dimmed
/// towards the edges. Turning to another profile shuffles its posters in,
/// tile by tile. Plain tiles stand in for a profile without posters, and
/// with Reduce Motion the wall holds still and the posters cross-fade.
struct TVPosterWall: View {
    let posters: [UIImage]
    /// Counts the times the posters changed; each change shuffles the wall.
    var generation = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    private let columns = 9
    private let perColumn = 5
    private let spacing: CGFloat = 20

    var body: some View {
        GeometryReader { screen in
            let wallWidth = screen.size.width * 1.3
            let tileWidth = (wallWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let tileHeight = tileWidth * 1.5
            // A column holds its posters twice, so moving it by one set
            // lands on the same picture and the drift never shows a seam.
            let loop = CGFloat(perColumn) * (tileHeight + spacing)
            ZStack {
                Color.black
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        let rises = column.isMultiple(of: 2)
                        VStack(spacing: spacing) {
                            ForEach(0..<perColumn * 2, id: \.self) { row in
                                shuffledTile(
                                    column: column, row: row % perColumn,
                                    size: CGSize(width: tileWidth, height: tileHeight)
                                )
                            }
                        }
                        .offset(y: rises == isDrifting ? -loop : 0)
                        .animation(
                            reduceMotion ? nil : .linear(duration: rises ? 95 : 120).repeatForever(autoreverses: false),
                            value: isDrifting
                        )
                    }
                }
                .frame(width: wallWidth, height: screen.size.height * 1.5, alignment: .top)
                .rotationEffect(.degrees(-9))
                .opacity(0.55)
                RadialGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .black.opacity(0.82), location: 0.6),
                        .init(color: .black.opacity(0.97), location: 1)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0, endRadius: screen.size.width * 0.62
                )
            }
            .frame(width: screen.size.width, height: screen.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { isDrifting = !reduceMotion }
    }

    /// A tile that swaps its poster when the wall's posters change: the old
    /// card shrinks away as the new one grows in, each tile at its own
    /// moment so the wall looks shuffled. Only the tile changes identity,
    /// never its column, which would restart the drift. Both copies of a
    /// poster in a column share their moment, so the loop keeps no seam.
    private func shuffledTile(column: Int, row: Int, size: CGSize) -> some View {
        ZStack {
            tile(column: column, row: row)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .id(generation)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.55).combined(with: .opacity))
        }
        .frame(width: size.width, height: size.height)
        .animation(shuffle(column: column, row: row), value: generation)
    }

    private func shuffle(column: Int, row: Int) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.4) }
        // A steady scatter over 0.6 seconds, the same on every shuffle.
        let step = (column &* 7 &+ row &* 11 &+ column &* row &* 3) % 13
        return .spring(duration: 0.5, bounce: 0.22).delay(Double(step) / 12 * 0.6)
    }

    @ViewBuilder
    private func tile(column: Int, row: Int) -> some View {
        let index = column * perColumn + row
        if posters.isEmpty {
            Color.white.opacity(0.07 + 0.03 * Double((column + row) % 3))
        } else {
            Image(uiImage: posters[index % posters.count])
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}
#endif
