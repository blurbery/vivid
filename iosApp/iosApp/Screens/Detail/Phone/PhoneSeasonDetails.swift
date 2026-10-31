import SwiftUI

#if !os(tvOS)
/// A season's Details: who made it and when it aired, side by side on a
/// glass strip.
struct MobileSeasonFacts: View {
    let detail: ItemDetail

    private struct Fact: Identifiable {
        /// The English label, so identity is the same in every language.
        let id: String
        let label: String
        let value: String
    }

    var body: some View {
        let facts = Self.facts(for: detail)
        if !facts.isEmpty {
            let shape = RoundedRectangle(cornerRadius: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 1, height: 42)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: fact.label.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: fact.value)
                                .font(.system(size: 14, weight: .regular))
                                .lineLimit(3)
                        }
                        .frame(width: 170, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
        }
    }

    private static func facts(for detail: ItemDetail) -> [Fact] {
        var facts: [Fact] = []
        func add(_ id: String, _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            facts.append(Fact(id: id, label: label, value: value))
        }
        let crew = detail.crew ?? []

        add("Director", String(localized: "Director"), crewNames(crew, jobs: ["director"]))
        let hasScreenplay = crew.contains { $0.job?.lowercased() == "screenplay" }
        add(
            "Writer",
            hasScreenplay ? String(localized: "Writer") : String(localized: "Written by"),
            crewNames(crew, jobs: ["writer", "screenplay", "story"])
        )
        add("Studio", String(localized: "Studio"), firstThree(detail.studios))
        add("Network", String(localized: "Network"), firstThree(detail.networks))
        add("Country", String(localized: "Country"), firstThree(detail.countries))
        add("Aired", String(localized: "Aired"), DetailDateFormatting.longDate(detail.airDate))
        add("Released", String(localized: "Released"), DetailDateFormatting.longDate(detail.releaseDate))
        add("First Aired", String(localized: "First Aired"), DetailDateFormatting.longDate(detail.firstAirDate))
        add("Last Aired", String(localized: "Last Aired"), DetailDateFormatting.longDate(detail.lastAirDate))
        return facts
    }

    private static func firstThree(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.prefix(3).joined(separator: ", ")
    }

    /// Distinct names sorted in plain string order (not credit order), the
    /// first three, then an ellipsis when there are more.
    private static func crewNames(_ crew: [CrewMember], jobs: Set<String>) -> String? {
        let names = Set(crew.filter { member in
            member.job.map { jobs.contains($0.lowercased()) } ?? false
        }.map(\.name)).sorted()
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? shown + ", …" : shown
    }
}
#endif
