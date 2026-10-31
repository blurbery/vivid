#if os(tvOS)
import SwiftUI

/// A small quality or rating badge: filled for resolutions, outlined
/// otherwise.
struct TVDetailTextBadge: View {
    let text: String
    let isFilled: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 18, weight: .bold))
            .lineLimit(1)
            .foregroundStyle(isFilled ? Color.black : Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white)
                }
            }
            .overlay {
                if !isFilled {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                }
            }
            .fixedSize()
    }
}

/// The compact pages' heading: the kind of title, its facts and genres,
/// then the content rating.
struct TVDetailCompactHeading: View {
    let tokens: [String]
    let genres: [String]
    let contentRating: String?

    var body: some View {
        HStack(spacing: 10) {
            headingText
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let contentRating {
                TVDetailTextBadge(text: contentRating, isFilled: false)
            }
        }
    }

    private var headingText: Text {
        var heading = AttributedString(tokens.first ?? "")
        heading.swiftUI.foregroundColor = Color.white.opacity(0.92)
        let rest = Array(tokens.dropFirst()) + genres
        if !rest.isEmpty {
            var tail = AttributedString(" \u{00B7} " + rest.joined(separator: " \u{00B7} "))
            tail.swiftUI.foregroundColor = Color.white.opacity(0.70)
            heading.append(tail)
        }
        return Text(heading)
    }
}

/// The year and runtime, the source badges and the TMDb score.
struct TVDetailTechnicalRow: View {
    let releaseFacts: [String]
    let badges: [String]
    let tmdbScore: Double?

    var body: some View {
        HStack(spacing: 10) {
            if !releaseFacts.isEmpty {
                Text(verbatim: releaseFacts.joined(separator: " \u{00B7} "))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
            }
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                TVDetailTextBadge(text: badge, isFilled: TVHeroMetadata.isResolutionBadge(badge))
            }
            if let tmdbScore {
                TMDbRatingBadge(
                    rating: tmdbScore,
                    logoHeight: 24,
                    font: .system(size: 24, weight: .semibold),
                    color: Color.white.opacity(0.92)
                )
                .padding(.leading, 4)
            }
        }
        .lineLimit(1)
        .frame(height: 40, alignment: .leading)
    }
}

/// The older layout's and season page's metadata: a source row for
/// episodes, then the facts row.
struct TVDetailMetadataSlots: View {
    /// True for an episode shown under its series title.
    let separatesSourceRow: Bool
    let sourceTokens: [String]
    let facts: [String]
    let contentRating: String?

    var body: some View {
        if separatesSourceRow {
            if !sourceTokens.isEmpty {
                slot { sourceRow }
            }
            if showsFactsRow(includingSource: false) {
                slot { factsRow(includingSource: false) }
            }
        } else if showsFactsRow(includingSource: true) {
            slot { factsRow(includingSource: true) }
        }
    }

    private func slot(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(height: 36, alignment: .leading)
            .clipped()
    }

    private func showsFactsRow(includingSource: Bool) -> Bool {
        !facts.isEmpty || (includingSource && !sourceTokens.isEmpty) || contentRating != nil
    }

    private var sourceRow: some View {
        HStack(spacing: 14) {
            ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                if index > 0 {
                    Text("·")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Text(verbatim: token)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
        }
    }

    private func factsRow(includingSource: Bool) -> some View {
        HStack(spacing: 14) {
            if let contentRating {
                Text(verbatim: contentRating)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.78), lineWidth: 1.5))
                    .fixedSize(horizontal: true, vertical: false)
            }
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { divider }
                Text(verbatim: fact)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            if includingSource {
                ForEach(Array(sourceTokens.enumerated()), id: \.offset) { index, token in
                    if !facts.isEmpty || index > 0 { divider }
                    Text(verbatim: token)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.90))
                }
            }
        }
    }

    private var divider: some View {
        Text("·")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
    }
}

// MARK: - Playback summary

/// The version and audio values for the playback summary.
struct TVDetailPlaybackSummaryValues {
    var version: String?
    var audio: String?

    /// Unknown values (no version) draw as placeholders.
    @MainActor
    init(version current: FileVersion?) {
        guard let current else {
            version = nil
            audio = nil
            return
        }
        let quality = Self.quality(current.resolution)
        let range = DetailPlaybackFormatting.dynamicRangeLabel(current)
            ?? DetailPlaybackFormatting.normalizedVideoCodec(current.codecVideo)
        let parts = [quality, range].compactMap { $0 }
        version = parts.isEmpty ? String(localized: "Auto") : parts.joined(separator: " \u{00B7} ")

        let tracks = current.audioTracks ?? []
        let index = tracks.firstIndex(where: { $0.isDefault == true }) ?? (tracks.isEmpty ? nil : 0)
        audio = DetailPlaybackFormatting.audioTechnicalSummary(version: current, selectedAudioTrackIndex: index)
            ?? String(localized: "Auto")
    }

    /// "4K", "FHD" or "HD" from the resolution text.
    static func quality(_ resolution: String?) -> String? {
        let text = (resolution ?? "").lowercased()
        let tail = text.split(separator: "x", omittingEmptySubsequences: false).last.map(String.init) ?? text
        let height = Int(tail.filter(\.isNumber)) ?? 0
        if text.contains("4k") || text.contains("uhd") || height >= 2160 { return "4K" }
        if height >= 1080 || text.contains("fhd") { return "FHD" }
        if !text.isEmpty { return "HD" }
        return nil
    }
}

/// Version and audio at a glance, under the hero on the older layout and
/// the season page.
struct TVDetailPlaybackSummary: View {
    let values: TVDetailPlaybackSummaryValues

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            item(label: String(localized: "Version"), systemImage: "square.stack", value: values.version)
            item(label: String(localized: "Audio"), systemImage: "speaker.wave.2", value: values.audio)
        }
        .frame(width: 656, height: 40, alignment: .leading)
    }

    private func item(label: String, systemImage: String, value: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Group {
                if let value {
                    Text(verbatim: value)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 84, height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.10)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { Text("\(label), \($0)") } ?? Text("\(label), loading"))
    }
}
#endif
