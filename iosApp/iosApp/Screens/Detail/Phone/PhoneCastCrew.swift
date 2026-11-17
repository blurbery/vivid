import SwiftUI

#if !os(tvOS)
/// Cast & Crew: directors, then writers, then cast, with each group after
/// the first introduced by its name turned on its side.
struct MobileCastCrewSection: View {
    let cast: [CastMember]
    let crew: [CrewMember]
    let onSelectPerson: (String) -> Void

    @State private var preferences = UICustomizationPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobileSectionHeader(title: Text("Cast & Crew"))
                .padding(.horizontal, 16)
            rail
        }
    }

    private var rail: some View {
        let groups = CastCrewGrouping.groups(cast: cast, crew: crew, maxCast: 24, maxCrewPerGroup: 6)
        let width = VividTheme.posterCardWidth * preferences.cardPresentation.posterSize.scale
        let height = width * VividTheme.posterCardHeight / VividTheme.posterCardWidth
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        divider(label: group.label, height: height)
                    }
                    ForEach(group.people) { person in
                        card(person, width: width, height: height)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
    }

    private func divider(label: String, height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Color.vividSecondaryText)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 12, height: height)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: height)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isHeader)
    }

    private func card(_ person: CastCrewPerson, width: CGFloat, height: CGFloat) -> some View {
        Button {
            if let personId = person.personId {
                onSelectPerson(personId)
            }
        } label: {
            VStack(alignment: .center, spacing: 8) {
                photo(person, width: width, height: height)
                VStack(alignment: .center, spacing: 2) {
                    Text(verbatim: person.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let role = person.role, !role.isEmpty {
                        Text(verbatim: role)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func photo(_ person: CastCrewPerson, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
        return ZStack {
            Color.vividSurfaceElevated
            if let url = person.photoUrl, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: person.photoThumbhash, contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: width * 0.4))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}
#endif
