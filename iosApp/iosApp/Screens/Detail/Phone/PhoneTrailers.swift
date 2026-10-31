import SwiftUI

#if !os(tvOS)
/// TMDb trailers, opened in YouTube. Always one element of the page's
/// section stack, so it keeps loading even while it has nothing to show.
struct MobileTrailersSection: View {
    let contentId: String

    @State private var tmdb = TVTMDbStore.shared
    @State private var videos: [ItemVideo] = []
    @State private var isLoading = false
    @State private var didFail = false
    @State private var retryCount = 0
    @State private var pendingTrailer: TrailerRailEntry?
    @Environment(\.openURL) private var openURL

    private struct LoadKey: Equatable {
        let context: String
        let contentId: String
        let retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tmdb.isConfigured {
                if !videos.isEmpty {
                    MobileTrailersRail(entries: videos.map { TrailerRailEntry.remote($0) }) { entry in
                        pendingTrailer = entry
                    }
                } else {
                    MobileSectionHeader(title: Text("Trailers"))
                        .padding(.horizontal, 16)
                    status
                        .padding(.horizontal, 16)
                }
            }
        }
        .task(id: LoadKey(context: tmdb.contextKey, contentId: contentId, retry: retryCount)) {
            await load()
        }
        .alert(
            "Open in YouTube?",
            isPresented: Binding(
                get: { pendingTrailer != nil },
                set: { if !$0 { pendingTrailer = nil } }
            ),
            presenting: pendingTrailer
        ) { entry in
            Button("Open") { open(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(verbatim: entry.title)
        }
    }

    @ViewBuilder
    private var status: some View {
        if isLoading {
            ProgressView("Loading trailers…")
        } else if didFail {
            Button("Couldn’t load trailers. Try again") {
                retryCount += 1
            }
        } else {
            Text("No trailers available for this title.")
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        videos = []
        didFail = false
        isLoading = true
        guard tmdb.isConfigured else {
            isLoading = false
            return
        }
        do {
            let loaded = try await tmdb.videos(contentId: contentId)
            guard !Task.isCancelled else { return }
            videos = loaded
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            didFail = true
            isLoading = false
        }
    }

    /// Opens the YouTube app when it's installed, otherwise the web page.
    private func open(_ entry: TrailerRailEntry) {
        guard case .remote(let video) = entry,
              let appURL = TrailerRail.youtubeDeepLinkURL(siteKey: video.siteKey),
              let webURL = TrailerRail.youtubeWatchURL(siteKey: video.siteKey) else { return }
        let hasApp = URL(string: "youtube://").map { UIApplication.shared.canOpenURL($0) } ?? false
        openURL(hasApp ? appURL : webURL)
    }
}

/// The Trailers header and a rail of YouTube cards.
private struct MobileTrailersRail: View {
    let entries: [TrailerRailEntry]
    let onSelect: (TrailerRailEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobileSectionHeader(title: Text("Trailers"))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in
                        card(entry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .phoneMediaRailBounds()
            }
        }
    }

    private func card(_ entry: TrailerRailEntry) -> some View {
        let kind = ExtraKindLabels.label(for: entry.kind)
        return Button {
            onSelect(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: kind.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(Color.vividOnSurface.opacity(0.55))
                    Text(verbatim: entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: 240, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(entry.title), \(kind)"))
    }

    private func thumbnail(_ entry: TrailerRailEntry) -> some View {
        let size = CGSize(width: 240, height: 135)
        let still = Self.stillURL(entry)
        return ZStack {
            if let still {
                AsyncImageView(url: still.absoluteString, targetSize: size, contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.vividSurfaceElevated)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
    }

    /// The YouTube still, when the video's key makes a valid address.
    private static func stillURL(_ entry: TrailerRailEntry) -> URL? {
        guard case .remote(let video) = entry else { return nil }
        return TrailerRail.thumbnailURL(siteKey: video.siteKey)
    }
}
#endif
