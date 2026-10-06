#if !os(tvOS)
import SwiftUI

/// Horizontal cast and crew rail for the phone detail page. Portrait poster
/// thumbnails with each person's name and role beneath, grouped as directors,
/// then writers, then the cast in the server's billing order, with a labelled
/// divider between groups. Mirrors `TVDetailCastRail` semantics, scaled down
/// for touch.
struct PhoneCastRail: View {
    let cast: [CastMember]
    let crew: [CrewMember]
    let onTap: (String) -> Void
    @State private var uiCustomization = UICustomizationPreferences.shared

    // Same poster size as the More Like This and home rails.
    private var cardWidth: CGFloat {
        VividTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var posterHeight: CGFloat {
        cardWidth * (VividTheme.posterCardHeight / VividTheme.posterCardWidth)
    }
    private let cardSpacing: CGFloat = 12
    private let maxEntries = 24
    private let maxCrewPerGroup = 6

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        divider(label: group.label)
                    }
                    ForEach(group.people) { person in
                        card(for: person)
                    }
                }
            }
            .padding(.horizontal, VividTheme.safePadding)
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
    }

    // MARK: - Groups

    private struct RailPerson: Identifiable {
        let id: String
        let personId: String?
        let name: String
        let role: String?
        let photoUrl: String?
    }

    private struct RailGroup: Identifiable {
        let id: String
        let label: String
        let people: [RailPerson]
    }

    private var groups: [RailGroup] {
        // A person credited more than once (a writer-director, or both
        // screenplay and story) only appears in their first group.
        var seen = Set<String>()
        func crewGroup(_ id: String, label: String, role: (String?) -> String?) -> RailGroup {
            var people: [RailPerson] = []
            for member in crew {
                guard people.count < maxCrewPerGroup, let title = role(member.job),
                      seen.insert(member.personId ?? member.name.lowercased()).inserted else { continue }
                people.append(RailPerson(id: "\(id)-\(people.count)", personId: member.personId,
                                         name: member.name, role: title, photoUrl: member.photoUrl))
            }
            return RailGroup(id: id, label: label, people: people)
        }

        let directors = crewGroup("directors", label: "Directors") { job in
            Self.normalised(job) == "director" ? "Director" : nil
        }
        let writers = crewGroup("writers", label: "Writers") { job in
            let job = Self.normalised(job)
            guard Self.writerJobs.contains(job) else { return nil }
            return job == "creator" ? "Creator" : "Writer"
        }
        let castGroup = RailGroup(
            id: "cast",
            label: "Cast",
            people: cast.prefix(maxEntries).enumerated().map { index, member in
                RailPerson(id: "cast-\(index)", personId: member.personId, name: member.name,
                           role: member.character, photoUrl: member.photoUrl)
            }
        )
        return [directors, writers, castGroup].filter { !$0.people.isEmpty }
    }

    /// Writing credits as Silo (Writer) and Jellyfin's TMDb data (Screenplay,
    /// Story, Creator and so on) name them.
    private static let writerJobs: Set<String> = [
        "writer", "screenplay", "story", "teleplay", "novel", "creator",
    ]

    private static func normalised(_ job: String?) -> String {
        (job ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Views

    private func divider(label: String) -> some View {
        HStack(spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Color.vividSecondaryText)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 12, height: posterHeight)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: posterHeight)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    private func card(for person: RailPerson) -> some View {
        Button {
            if let personId = person.personId { onTap(personId) }
        } label: {
            VStack(spacing: 8) {
                photo(url: person.photoUrl)
                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.vividOnSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let role = person.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.vividSecondaryText)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: cardWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func photo(url: String?) -> some View {
        ZStack {
            Color.vividSurfaceElevated
            if let url, !url.isEmpty {
                AsyncImageView(url: url, contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: cardWidth * 0.4))
                    .foregroundColor(.vividSecondaryText)
            }
        }
        .frame(width: cardWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
#endif
