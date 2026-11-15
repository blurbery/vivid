#if os(tvOS)
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Small copies of library posters, kept on this Apple TV so Who's watching
/// can draw its wall before anyone is signed in and without asking a server.
/// They come from the signed-in profile's Home rows, never from its Continue
/// Watching or Next Up rows, so the wall says nothing about what anyone
/// watched. They stay out of the saved account record and the iCloud vault.
enum TVPosterWallStore {
    private static let writer = Writer()
    /// Posters kept per profile, and drawn on the wall in all.
    private static let perProfile = 40
    private static let wallLimit = 60

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

    /// Saves posters from a fresh Home response for the signed-in profile.
    @MainActor
    static func capture(_ response: SectionsResponse, scope: String) {
        guard let account = TVSavedAccountStore.shared.activeAccount,
              Self.scope(for: account) == scope, !isLocked(account) else {
            Task.detached(priority: .utility) { await writer.delete(scope: scope) }
            return
        }
        let history: Set<String> = ["continue_watching", "in_progress", "next_up"]
        let rows = response.sections
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

    /// The wall's posters: the saved profiles' posters mixed together.
    @MainActor
    static func posters(for accounts: [TVSavedAccount]) async -> [UIImage] {
        let folders = accounts.compactMap { account -> URL? in
            guard !isLocked(account), let scope = scope(for: account) else { return nil }
            return folder(scope)
        }
        let limit = wallLimit
        return await Task.detached(priority: .userInitiated) {
            let files = folders.map { folder -> [URL] in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return names.filter { $0.hasSuffix(".jpg") }.sorted().map { folder.appendingPathComponent($0) }
            }
            var mixed: [URL] = []
            var seen = Set<String>()
            var depth = 0
            while mixed.count < limit, files.contains(where: { $0.count > depth }) {
                for list in files where list.count > depth && mixed.count < limit {
                    // Two profiles on one server save the same title once.
                    if seen.insert(list[depth].lastPathComponent).inserted { mixed.append(list[depth]) }
                }
                depth += 1
            }
            return mixed.compactMap { UIImage(contentsOfFile: $0.path)?.preparingForDisplay() }
        }.value
    }

    /// One writer, so a profile's folder changes in one place.
    private actor Writer {
        func save(_ posters: [(name: String, url: URL)], scope: String) async {
            let folder = TVPosterWallStore.folder(scope)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for poster in posters {
                let file = folder.appendingPathComponent(poster.name)
                guard !FileManager.default.fileExists(atPath: file.path),
                      let data = try? await VividImagePipeline.shared.data(
                          for: VividImageRequest(url: poster.url, cacheScope: scope)
                      ) else { continue }
                Self.writePoster(data, to: file)
            }
            let kept = Set(posters.map(\.name))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where !kept.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }

        func delete(scope: String) {
            try? FileManager.default.removeItem(at: TVPosterWallStore.folder(scope))
        }

        /// Saves the poster at the size the wall draws it, as a JPEG.
        private static func writePoster(_ data: Data, to file: URL) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(
                      file as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                  ) else { return }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
            )
            CGImageDestinationFinalize(destination)
        }
    }
}

/// Who's watching's background: a tilted wall of posters drifting slowly,
/// alternate columns in opposite directions, dimmed towards the edges, with
/// a glow in the focused profile's colour behind the profiles. Plain tiles
/// stand in until a profile's Home has loaded on this Apple TV, and the wall
/// holds still with Reduce Motion.
struct TVPosterWall: View {
    let posters: [UIImage]
    /// The focused profile's hue, from 0 to 1.
    var glowHue: Double?

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
                                tile(column: column, row: row % perColumn)
                                    .frame(width: tileWidth, height: tileHeight)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: screen.size.width * 0.62
                )
                RadialGradient(
                    colors: [glowColor.opacity(glowHue == nil ? 0 : 0.42), .clear],
                    center: UnitPoint(x: 0.5, y: 0.44), startRadius: 0, endRadius: screen.size.width * 0.27
                )
                .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.6), value: glowHue)
            }
            .frame(width: screen.size.width, height: screen.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { isDrifting = !reduceMotion }
    }

    private var glowColor: Color {
        Color(hue: glowHue ?? 0, saturation: 0.7, brightness: 0.95)
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
