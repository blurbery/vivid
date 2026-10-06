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
            // Top-aligned on iPad too, so posters line up when a name wraps.
            LazyHStack(alignment: .top, spacing: cardSpacing) {
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

    private var groups: [CastCrewGroup] {
        CastCrewGrouping.groups(cast: cast, crew: crew, maxCast: maxEntries, maxCrewPerGroup: maxCrewPerGroup)
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

    private func card(for person: CastCrewPerson) -> some View {
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
