#if !os(tvOS)
import SwiftUI

/// "Details" key/value list rendered below the hero. Mirrors
/// `TVDetailFactsSection` — same data sources (crew, studios, networks,
/// dates) — but laid out as a phone-friendly inset list with thin
/// dividers and tight rows.
struct PhoneDetailFactsSection: View {
    let detail: ItemDetail

    private let maxCreditNames = 3

    var body: some View {
        let facts = assembleFacts()
        if !facts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.label) { index, fact in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 42)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fact.label.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(fact.value)
                                .font(.system(size: 14))
                                .lineLimit(3)
                        }
                        .frame(width: 170, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
    }

    private struct Fact {
        let label: String
        let value: String
    }

    private func assembleFacts() -> [Fact] {
        var facts: [Fact] = []

        if let directors = creditNames(forJobs: ["Director"]), !directors.isEmpty {
            facts.append(Fact(label: "Director", value: directors))
        }
        if let writers = creditNames(forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(Fact(label: writerLabel, value: writers))
        }
        if let studios = detail.studios, !studios.isEmpty {
            facts.append(Fact(label: "Studio", value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(Fact(label: "Network", value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(Fact(label: "Country", value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(Fact(label: "Aired", value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: "Released", value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(Fact(label: "First Aired", value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(Fact(label: "Last Aired", value: lastAired))
        }
        return facts
    }

    private var writerLabel: String {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? "Writer" : "Written by"
    }

    private func creditNames(forJobs jobs: [String]) -> String? {
        guard let crew = detail.crew else { return nil }
        let lowered = jobs.map { $0.lowercased() }
        let names = crew
            .filter { member in
                guard let job = member.job?.lowercased() else { return false }
                return lowered.contains(job)
            }
            .map(\.name)
        if names.isEmpty { return nil }
        let trimmed = Array(Set(names)).sorted()
        let joined = trimmed.prefix(maxCreditNames).joined(separator: ", ")
        return trimmed.count > maxCreditNames ? "\(joined), …" : joined
    }
}
#endif
