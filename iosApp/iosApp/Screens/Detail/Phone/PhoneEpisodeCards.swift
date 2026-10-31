import SwiftUI

#if !os(tvOS)
/// How an episode reads on cards, rows and to VoiceOver.
enum MobileEpisodeText {
    /// The episode's own title, even an empty one, or "Episode 4".
    static func title(_ episode: EpisodeListItem) -> String {
        episode.title ?? String(localized: "Episode \(String(episode.episodeNumber))")
    }

    /// The air date and running time, for VoiceOver.
    static func metadata(_ episode: EpisodeListItem) -> String? {
        var parts: [String] = []
        if let aired = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(aired)
        }
        if let runtime = episode.runtime, runtime > 0 {
            if runtime >= 60 {
                parts.append(String(localized: "\(runtime / 60)h \(runtime % 60)m"))
            } else {
                parts.append(String(localized: "\(runtime)m"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// How far into the episode the viewer is, when it's part watched.
    static func progress(_ episode: EpisodeListItem) -> Double? {
        guard let position = episode.userData?.positionSeconds,
              let duration = episode.userData?.durationSeconds,
              duration > 0, position > 0, position < duration else { return nil }
        return position / duration
    }

    static func spokenDescription(_ episode: EpisodeListItem, isCurrent: Bool) -> String {
        episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: metadata(episode),
            isCurrent: isCurrent,
            isPlayed: episode.userData?.played == true
        )
    }
}

/// An episode's still, softened and marked when it could spoil the story.
struct MobileEpisodeStill: View {
    let episode: EpisodeListItem
    let size: CGSize
    var symbolSize: CGFloat = 22

    var body: some View {
        let covered = episode.hidesSpoilers
        AsyncImageView(
            url: episode.stillUrl ?? "",
            thumbhash: episode.stillThumbhash,
            targetSize: covered ? EpisodeSpoilerPolicy.coveredStillDecodeSize : size,
            contentMode: .fill,
            softening: covered ? EpisodeSpoilerPolicy.coveredStillSoftening : nil
        )
        .frame(width: size.width, height: size.height)
        .clipped()
        .spoilerCovered(covered, symbolSize: symbolSize)
    }
}

/// The watched mark and running time in a dark capsule, then the resume
/// bar when the episode is part watched.
struct MobileEpisodeStatus: View {
    let episode: EpisodeListItem
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            HStack(spacing: 4) {
                if episode.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                }
                if let runtime = episode.runtime, runtime > 0 {
                    Text("\(runtime)m")
                }
            }
            .font(.system(size: isCompact ? 10 : 12))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            if let progress = MobileEpisodeText.progress(episode) {
                ResumeProgressBar(value: progress, duration: episode.userData?.durationSeconds, height: 5, inset: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A season's episodes as a rail of cards that keeps the current episode
/// in view. On the series page the card that comes to rest at the anchor
/// becomes the chosen episode.
struct MobileEpisodeCarousel: View {
    let episodes: [EpisodeListItem]
    let currentEpisodeId: String?
    let selectsCentredCard: Bool
    let captionOverride: CardCaptionStyle?
    let onSelect: (EpisodeListItem) -> Void
    let onPlay: ((EpisodeListItem) -> Void)?

    @State private var anchoredId: String?
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var viewerDragged = false
    @State private var preferences = UICustomizationPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = preferences.cardPresentation
        let caption = captionOverride ?? presentation.caption
        let width = 240 * presentation.posterSize.scale
        let isPhone = HorizontalMediaRailLayout.isPhone
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(episodes) { episode in
                    card(episode, width: width, caption: caption)
                        .id(episode.contentId)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, isPhone ? 0 : 16)
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
        .contentMargins(.horizontal, isPhone ? 16 : 0, for: .scrollContent)
        .scrollTargetBehavior(HorizontalMediaRailLayout.targetBehavior)
        .scrollPosition(id: $anchoredId, anchor: HorizontalMediaRailLayout.scrollAnchor)
        .onScrollPhaseChange { _, phase in
            scrollPhase = phase
            if phase == .interacting {
                viewerDragged = true
            }
            guard phase == .idle else { return }
            let dragged = viewerDragged
            viewerDragged = false
            guard selectsCentredCard else { return }
            // Jellyfin only follows the viewer's own drags, so layout and
            // programmatic scrolling never change the episode.
            if MediaServerProvider.active == .jellyfin, !dragged { return }
            chooseAnchoredEpisode()
        }
        .onAppear {
            anchoredId = currentEpisodeId ?? episodes.first?.contentId
        }
        .onChange(of: episodes.map(\.contentId)) { _, ids in
            guard !ids.isEmpty, !ids.contains(where: { $0 == anchoredId }) else { return }
            let target = currentEpisodeId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                anchoredId = target
            }
        }
        .onChange(of: currentEpisodeId) { _, id in
            guard let id, id != anchoredId else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0)) {
                anchoredId = id
            }
        }
        .onChange(of: anchoredId) { _, _ in
            guard selectsCentredCard, MediaServerProvider.active == .emby, scrollPhase == .idle else { return }
            chooseAnchoredEpisode()
        }
    }

    private func chooseAnchoredEpisode() {
        guard let anchoredId, anchoredId != currentEpisodeId,
              let episode = episodes.first(where: { $0.contentId == anchoredId }) else { return }
        onSelect(episode)
    }

    private func card(_ episode: EpisodeListItem, width: CGFloat, caption: CardCaptionStyle) -> some View {
        let isCurrent = episode.contentId == currentEpisodeId
        let stillSize = CGSize(width: width, height: width * 9 / 16)
        return ZStack(alignment: .top) {
            Button {
                onSelect(episode)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    still(episode, size: stillSize, isCurrent: isCurrent)
                    if caption.showsTitle {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EPISODE \(String(episode.episodeNumber))")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary)
                            Text(verbatim: MobileEpisodeText.title(episode))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isCurrent ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if caption.showsMetadata {
                                Text(verbatim: episode.overview ?? "")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Color.vividSecondaryText)
                                    .lineLimit(2, reservesSpace: true)
                                    .lineSpacing(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: DetailDateFormatting.abbreviatedDate(episode.airDate) ?? "")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: MobileEpisodeText.spokenDescription(episode, isCurrent: isCurrent)))

            if let onPlay {
                Button {
                    onPlay(episode)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.94)))
                }
                .buttonStyle(.plain)
                .padding(.top, (stillSize.height - 42) / 2)
                .accessibilityLabel(Text("Play Season \(String(episode.seasonNumber)), Episode \(String(episode.episodeNumber))"))
            }
        }
        .modifier(MobileEpisodeWatchedMenu(episode: episode))
    }

    private func still(_ episode: EpisodeListItem, size: CGSize, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ZStack(alignment: .bottom) {
            MobileEpisodeStill(episode: episode, size: size)
            MobileEpisodeStatus(episode: episode)
                .padding(12)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.stroke(isCurrent ? Color.white.opacity(0.70) : .clear, lineWidth: isCurrent ? 2 : 0))
        .animation(.easeOut(duration: 0.18), value: isCurrent)
    }
}

/// Three grey cards while a season's episodes load.
struct MobileEpisodeCarouselSkeleton: View {
    let captionOverride: CardCaptionStyle?

    @State private var preferences = UICustomizationPreferences.shared

    var body: some View {
        let presentation = preferences.cardPresentation
        let caption = captionOverride ?? presentation.caption
        let width = 240 * presentation.posterSize.scale
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.09 + 0.01 * Double(index)))
                            .frame(width: width, height: width * 9 / 16)
                        if caption.showsTitle {
                            VStack(alignment: .leading, spacing: 4) {
                                Self.bar(width: 62, height: 8, opacity: 0.12)
                                Self.bar(width: 0.68 * width, height: 12, opacity: 0.16)
                                if caption.showsMetadata {
                                    Self.bar(width: 0.42 * width, height: 9, opacity: 0.10)
                                    Self.bar(width: 0.92 * width, height: 9, opacity: 0.09)
                                    Self.bar(width: 0.78 * width, height: 9, opacity: 0.09)
                                    Self.bar(width: 0.55 * width, height: 9, opacity: 0.09)
                                }
                            }
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func bar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
    }
}
#endif
