import SwiftUI

/// The playback stats as sections of label and value rows: Source and Media,
/// then Buffer, Network and Engine. Apple TV's Info HUD shows it in three
/// columns with TV type sizes. A section with no rows is left out.
struct PlaybackStatsPanel: View {
    let stats: PlaybackStats
    var usesTVTypography = false
    var usesThreeColumnLayout = false

    /// Scroll targets for the HUD's paging, one per section header.
    static let sourceSectionID = "stats-source"
    static let mediaSectionID = "stats-media"
    static let bufferSectionID = "stats-buffer"
    static let networkSectionID = "stats-network"
    static let engineSectionID = "stats-engine"

    var body: some View {
        Group {
            if usesThreeColumnLayout {
                HStack(alignment: .top, spacing: 24) {
                    column(leftSections)
                    divider
                    column(Array(rightSections.prefix(2)))
                    divider
                    column(Array(rightSections.suffix(1)))
                }
            } else {
                column(leftSections + rightSections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var leftSections: [StatsSection] {
        [
            .init(id: Self.sourceSectionID, title: String(localized: "Source", comment: "Playback stats section"), rows: stats.sourceRows),
            .init(id: Self.mediaSectionID, title: String(localized: "Media", comment: "Playback stats section"), rows: stats.mediaRows)
        ]
    }

    private var rightSections: [StatsSection] {
        [
            .init(id: Self.bufferSectionID, title: String(localized: "Buffer", comment: "Playback stats section"), rows: stats.bufferRows),
            .init(id: Self.networkSectionID, title: String(localized: "stats.network", defaultValue: "Network", comment: "Playback stats section about the network connection"), rows: stats.networkRows),
            .init(id: Self.engineSectionID, title: String(localized: "Engine", comment: "Playback stats section"), rows: stats.engineRows)
        ]
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func column(_ sections: [StatsSection]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: usesTVTypography ? 6 : 10) {
            ForEach(sections) { section in
                rows(for: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rows(for section: StatsSection) -> some View {
        if !section.rows.isEmpty {
            GridRow {
                Text(section.title.uppercased())
                    .font(headerFont)
                    .foregroundStyle(.white.opacity(0.52))
                    .gridColumnAlignment(.trailing)
                    .id(section.id)
                Color.clear
                    .frame(height: 1)
            }
            ForEach(section.rows, id: \.0) { row in
                GridRow {
                    Text(PlaybackStats.displayLabel(row.0))
                        .font(labelFont)
                        .foregroundStyle(.white.opacity(0.74))
                    Text(row.1)
                        .font(valueFont)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }
        }
    }

    private var headerFont: Font {
        usesTVTypography
            ? .system(size: 13, weight: .semibold)
            : .caption.weight(.semibold)
    }

    private var labelFont: Font {
        usesTVTypography
            ? .system(size: 20, weight: .medium)
            : .callout.weight(.medium)
    }

    private var valueFont: Font {
        usesTVTypography
            ? .system(size: 20, weight: .regular)
            : .callout.monospacedDigit()
    }

    private struct StatsSection: Identifiable {
        let id: String
        let title: String
        let rows: [(String, String)]
    }
}
