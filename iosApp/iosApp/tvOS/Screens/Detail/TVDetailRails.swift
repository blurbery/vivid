#if os(tvOS)
import SwiftUI

/// The small upper-case label and large title above a detail section.
struct TVDetailSectionHeader: View {
    private let title: Text
    private let label: Text?

    init(_ title: LocalizedStringKey, label: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.label = label.map { Text($0) }
    }

    /// A title known only at run time, such as a collection's name.
    init(verbatim title: String) {
        self.title = Text(verbatim: title)
        self.label = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label {
                label
                    .font(.system(size: 17, weight: .bold))
                    .tracking(3.0)
                    .foregroundStyle(Color.vividOnSurface.opacity(0.55))
                    .textCase(.uppercase)
            }
            title
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)
        }
    }
}

// MARK: - Cast & Crew

/// Directors, writers and cast, each group introduced by a vertical label.
struct TVDetailCastRail: View {
    let cast: [CastMember]
    let crew: [CrewMember]
    let onSelectPerson: (String) -> Void

    @State private var homeCards = TVHomeCardPreferences.shared
    @FocusState private var focusedKey: String?

    var body: some View {
        let groups = CastCrewGrouping.groups(cast: cast, crew: crew, maxCast: 24, maxCrewPerGroup: 6)
        let photoWidth = VividTheme.Skyline.densePosterCardWidth * homeCards.presentation.posterSize.scale
        let photoSize = CGSize(width: photoWidth, height: photoWidth * 1.5)
        let firstKey = groups.first.flatMap { group in group.people.first.map { Self.key(group, $0) } }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 44) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        TVCastGroupDivider(label: group.label, height: photoSize.height)
                    }
                    ForEach(group.people) { person in
                        let key = Self.key(group, person)
                        TVCastPersonCard(
                            person: person,
                            photoSize: photoSize,
                            focus: $focusedKey,
                            focusKey: key
                        ) {
                            if let personId = person.personId {
                                onSelectPerson(personId)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
        .defaultFocus($focusedKey, firstKey, priority: .userInitiated)
    }

    private static func key(_ group: CastCrewGroup, _ person: CastCrewPerson) -> String {
        "\(group.id)|\(person.id)"
    }
}

private struct TVCastGroupDivider: View {
    let label: String
    let height: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: label)
                .textCase(.uppercase)
                .font(.system(size: 17, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(Color.vividSecondaryText)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 20, height: height)
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 2, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TVCastPersonCard: View {
    let person: CastCrewPerson
    let photoSize: CGSize
    var focus: FocusState<String?>.Binding
    let focusKey: String
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == focusKey }

    private var role: String? {
        guard let role = person.role, !role.isEmpty else { return nil }
        return role
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                photo
            }
            .buttonStyle(.card)
            .focused(focus, equals: focusKey)
            .accessibilityLabel(Text(verbatim: role.map { "\(person.name), \($0)" } ?? person.name))

            VStack(spacing: 4) {
                Text(verbatim: person.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let role {
                    Text(verbatim: role)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: photoSize.width)
    }

    private var photo: some View {
        ZStack {
            Color.vividSurfaceElevated
            if let url = person.photoUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: photoSize,
                    thumbhash: person.photoThumbhash,
                    contentMode: .fill
                )
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: photoSize.width * 0.4))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
    }
}

// MARK: - Trailers

/// YouTube trailers (and, in principle, local extras), hidden when empty.
struct TVDetailTrailersRail: View {
    let entries: [TrailerRailEntry]
    let onSelect: (TrailerRailEntry) -> Void

    @FocusState private var focusedId: String?

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TVDetailSectionHeader("Trailers")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 48) {
                        ForEach(entries) { entry in
                            TVTrailerCard(entry: entry, focus: $focusedId) {
                                onSelect(entry)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .focusSection()
                .defaultFocus($focusedId, entries.first?.id, priority: .userInitiated)
            }
        }
    }
}

private struct TVTrailerCard: View {
    let entry: TrailerRailEntry
    var focus: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == entry.id }

    private static let thumbnailSize = CGSize(width: 400, height: 225)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                thumbnail
            }
            .buttonStyle(.card)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .focused(focus, equals: entry.id)
            .accessibilityLabel(Text(verbatim: entry.title))

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: entry.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                    .lineLimit(1)
                if let secondary {
                    Text(verbatim: secondary)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: Self.thumbnailSize.width, alignment: .leading)
    }

    private var secondary: String? {
        switch entry {
        case .remote:
            return "YouTube"
        case .local(let extra):
            guard let seconds = extra.durationSeconds, seconds > 0 else { return nil }
            return PlayerTimeFormatter.formatHMS(Double(seconds))
        }
    }

    private var thumbnail: some View {
        ZStack {
            Color.vividSurfaceElevated
            artwork
            Circle()
                .fill(Color.black.opacity(isFocused ? 0.72 : 0.55))
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var artwork: some View {
        switch entry {
        case .remote(let video):
            if let url = TrailerRail.thumbnailURL(siteKey: video.siteKey) {
                CachedAsyncImage(url: url.absoluteString, targetSize: Self.thumbnailSize, contentMode: .fill)
            }
        case .local:
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(Color.vividSecondaryText)
        }
    }
}
#endif
