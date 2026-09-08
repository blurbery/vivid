#if os(tvOS)
import SwiftUI

/// "Details" block under the hero on tvOS — lists directors, writers,
/// studios/networks, countries, and release date in a single glass row.
///
/// Data is pulled from `detail.crew`, `detail.studios`, etc. The section
/// hides cleanly when no facts are available.
struct TVDetailFactsSection: View {
    let detail: ItemDetail

    private let maxCreditNames = 3
    @FocusState private var isFocused: Bool

    var body: some View {
        let facts = assembleFacts()
        if !facts.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.label) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 1)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(fact.label.uppercased())
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(fact.value)
                            .font(.system(size: 20, weight: .regular))
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
                tint: .white.opacity(isFocused ? 0.12 : 0.03)
            )
            .focusEffectDisabled()
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
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
