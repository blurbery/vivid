#if os(tvOS)
import SwiftUI

/// Horizontal cast and crew rail used on the tvOS item detail screen. Each
/// card is a focus-liftable portrait poster with the person's name and role,
/// grouped as directors, writers and cast with a labelled divider between
/// groups.
struct TVDetailCastRail: View {
    let cast: [CastMember]
    let crew: [CrewMember]
    let onTap: (String) -> Void
    /// Non-zero changes explicitly hand focus into the first cast card from
    /// the composite Series episode carousel.
    var focusRequest = 0
    var focusRequestIsActive = true
    var onFocusRequestFailed: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil

    // Same poster size and spacing as More Like This, following Home's
    // poster size preference.
    @State private var homeCards = TVHomeCardPreferences.shared
    private var photoWidth: CGFloat {
        VividTheme.Skyline.densePosterCardWidth * homeCards.presentation.posterSize.scale
    }
    private var photoHeight: CGFloat { photoWidth * 1.5 }
    private let cardSpacing: CGFloat = 44
    private let maxEntries = 24
    private let maxCrewPerGroup = 6
    @FocusState private var focusedCastId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Top-aligned so posters line up when a name wraps.
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            TVCastGroupDivider(label: group.label, height: photoHeight)
                        }
                        ForEach(group.people) { person in
                            TVCastCard(
                                person: person,
                                photoSize: CGSize(width: photoWidth, height: photoHeight),
                                focusedCastId: $focusedCastId,
                                onTap: onTap
                            )
                            .id(person.id)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .focusSection()
            .applyCastRailDefaultFocus(defaultFocusId, binding: $focusedCastId)
            .scrollClipDisabled()
            .task(id: "\(focusRequest):\(focusRequestIsActive)") {
                guard focusRequest > 0, focusRequestIsActive, let defaultFocusId else { return }
                // Disappearing or replacing this task must release its pending
                // handoff. The parent checks the captured generation and request
                // so an old cancellation cannot clear its replacement.
                defer {
                    if Task.isCancelled { onFocusRequestFailed?() }
                }
                // A previously scrolled cast strip may not have its first lazy
                // card mounted. Reveal it before handing focus across the boundary.
                proxy.scrollTo(defaultFocusId, anchor: .leading)
                for _ in 0..<12 {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    if focusedCastId == defaultFocusId { return }
                    focusedCastId = defaultFocusId
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
                guard !Task.isCancelled, focusedCastId != defaultFocusId else { return }
                onFocusRequestFailed?()
            }
            .onChange(of: focusedCastId) { _, id in
                if id != nil { onFocus?() }
            }
        }
    }

    private var groups: [CastCrewGroup] {
        CastCrewGrouping.groups(cast: cast, crew: crew, maxCast: maxEntries, maxCrewPerGroup: maxCrewPerGroup)
    }

    private var defaultFocusId: String? {
        groups.first?.people.first?.id
    }
}

private extension View {
    /// When focus enters the cast/crew rail, land on the first person rather
    /// than letting tvOS choose a geometrically-nearest card.
    @ViewBuilder
    func applyCastRailDefaultFocus(
        _ firstCastId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstCastId {
            self.defaultFocus(binding, firstCastId, priority: .userInitiated)
        } else {
            self
        }
    }
}

/// Non-focusable divider between groups: a rotated label beside a thin
/// line, the height of the posters.
private struct TVCastGroupDivider: View {
    let label: String
    let height: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            Text(label.uppercased())
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
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TVCastCard: View {
    let person: CastCrewPerson
    let photoSize: CGSize
    let focusedCastId: FocusState<String?>.Binding
    let onTap: (String) -> Void

    private var isFocused: Bool { focusedCastId.wrappedValue == person.id }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                if let personId = person.personId { onTap(personId) }
            } label: {
                photo
            }
            .buttonStyle(.card)
            .focused(focusedCastId, equals: person.id)
            .accessibilityLabel(person.name)
            VStack(spacing: 4) {
                Text(person.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isFocused ? .vividOnSurface : Color.vividOnSurface.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.vividSecondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }

        }
        .frame(width: photoSize.width)
    }

    @ViewBuilder
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
                    .foregroundColor(.vividSecondaryText)
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
    }
}

#endif
