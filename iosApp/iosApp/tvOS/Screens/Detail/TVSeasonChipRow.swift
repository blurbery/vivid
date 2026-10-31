#if os(tvOS)
import SwiftUI

/// The season page's row of season chips, centred on the selected season.
struct TVSeasonChipRow: View {
    let seasons: [Season]
    let selectedSeasonId: String?
    let onSelect: (Season) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var focusedId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(seasons, id: \.contentId) { season in
                        Button {
                            onSelect(season)
                        } label: {
                            Text(verbatim: Self.title(for: season))
                                .font(.system(size: 20, weight: season.contentId == selectedSeasonId ? .semibold : .medium))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(TVSeasonChipStyle(isSelected: season.contentId == selectedSeasonId))
                        .focused($focusedId, equals: season.contentId)
                        .accessibilityAddTraits(season.contentId == selectedSeasonId ? .isSelected : [])
                        .modifier(SeasonWatchedContextMenu(season: season))
                        .id(season.contentId)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
            .modifier(TVSeasonChipDefaultFocus(focus: $focusedId, selectedId: selectedSeasonId))
            .onChange(of: selectedSeasonId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let selectedSeasonId {
                    proxy.scrollTo(selectedSeasonId, anchor: .center)
                }
            }
            .onChange(of: focusedId) { _, id in
                onFocusChange?(id != nil)
            }
        }
    }

    /// The season's own title first, then "Specials" or "Season N".
    static func title(for season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return String(localized: "Specials") }
        return String(localized: "Season \(String(season.seasonNumber))")
    }
}

private struct TVSeasonChipDefaultFocus: ViewModifier {
    var focus: FocusState<String?>.Binding
    let selectedId: String?

    func body(content: Content) -> some View {
        if let selectedId {
            content.defaultFocus(focus, selectedId, priority: .userInitiated)
        } else {
            content
        }
    }
}

private struct TVSeasonChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct TVSeasonChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    private var fill: Color {
        if isFocused { return .white }
        return .white.opacity(isSelected ? 0.20 : 0.05)
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(Capsule().fill(fill))
            .scaleEffect((isFocused ? 1.04 : 1) * (configuration.isPressed ? 0.97 : 1))
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}

// MARK: - Details facts

/// The season page's credits and dates in one glass panel.
struct TVDetailFactsBlock: View {
    struct Fact: Identifiable {
        /// A stable English identity, so labels that translate alike never
        /// collide.
        let id: String
        let label: String
        let value: String
    }

    let facts: [Fact]

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: fact.label)
                        .textCase(.uppercase)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(verbatim: fact.value)
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 28)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vividGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: Color.white.opacity(isFocused ? 0.12 : 0.03)
        )
        .focusEffectDisabled()
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

    /// The facts for a season page, in display order, each only when known.
    static func facts(for detail: ItemDetail) -> [Fact] {
        let crew = detail.crew ?? []
        var facts: [Fact] = []

        let directors = crew.filter { ($0.job ?? "").lowercased() == "director" }.map(\.name)
        if let names = creditNames(directors) {
            facts.append(Fact(id: "Director", label: String(localized: "Director"), value: names))
        }

        let writerJobs: Set<String> = ["writer", "screenplay", "story"]
        let writers = crew.filter { writerJobs.contains(($0.job ?? "").lowercased()) }.map(\.name)
        if let names = creditNames(writers) {
            let hasScreenplay = crew.contains { ($0.job ?? "").lowercased() == "screenplay" }
            let label = hasScreenplay ? String(localized: "Writer") : String(localized: "Written by")
            facts.append(Fact(id: "Writer", label: label, value: names))
        }

        let lists: [(String, String, [String]?)] = [
            ("Studio", String(localized: "Studio"), detail.studios),
            ("Network", String(localized: "Network"), detail.networks),
            ("Country", String(localized: "Country"), detail.countries)
        ]
        for (id, label, values) in lists {
            let first = (values ?? []).prefix(3)
            if !first.isEmpty {
                facts.append(Fact(id: id, label: label, value: first.joined(separator: ", ")))
            }
        }

        let dates: [(String, String, String?)] = [
            ("Aired", String(localized: "Aired"), detail.airDate),
            ("Released", String(localized: "Released"), detail.releaseDate),
            ("First Aired", String(localized: "First Aired"), detail.firstAirDate),
            ("Last Aired", String(localized: "Last Aired"), detail.lastAirDate)
        ]
        for (id, label, raw) in dates {
            if let date = DetailDateFormatting.longDate(raw) {
                facts.append(Fact(id: id, label: label, value: date))
            }
        }
        return facts
    }

    /// Distinct names in plain string order, at most three, with an ellipsis
    /// when there are more.
    private static func creditNames(_ names: [String]) -> String? {
        let distinct = Array(Set(names)).sorted()
        guard !distinct.isEmpty else { return nil }
        let shown = distinct.prefix(3).joined(separator: ", ")
        return distinct.count > 3 ? shown + ", \u{2026}" : shown
    }
}
#endif
