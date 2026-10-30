import SwiftUI

/// A cast or crew member: portrait, details and biography, then their
/// filmography with All, Movies and Series filters.
struct PersonDetailView: View {
    let personId: Int

    @State private var model: PersonPageModel
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @State private var topChromeScroll = PhoneDetailScrollState()
    @State private var showsBiography = false
    @Environment(\.detailPullBackAction) private var pullBack
    @Environment(\.dismiss) private var dismiss
    #else
    @State private var showsFullBiography = false
    #endif

    init(personId: Int) {
        self.personId = personId
        _model = State(initialValue: PersonPageModel(personId: personId))
    }

    var body: some View {
        page
            .onAppear { model.resumeMetadataRefresh() }
            .task { await model.loadIfNeeded() }
            .onDisappear { model.stopMetadataRefresh() }
    }

    #if os(iOS)
    private var page: some View {
        pageState
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: VividTheme.topBarIconHitSize + 9)
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                PhoneDetailTopChrome(
                    title: "",
                    isScrollGlassEnabled: false,
                    scrollState: topChromeScroll,
                    leadingSystemName: "chevron.left",
                    leadingAccessibilityLabel: String(localized: "Back"),
                    onLeadingTap: goBack
                )
            }
            // Only the Back control steps back; the pull-down gesture is off here.
            .environment(\.detailPullBackAction, nil)
    }

    private func goBack() {
        if let pullBack { pullBack() } else { dismiss() }
    }
    #else
    private var page: some View { pageState }
    #endif

    @ViewBuilder
    private var pageState: some View {
        if let person = model.person {
            personContent(person)
        } else if let error = model.error {
            ErrorView(state: error, onRetry: retry)
        } else if model.isLoadingPerson || model.isLoadingFilmography {
            ProgressView()
                .tint(Color.vividOnSurface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .vividPageBackground()
        } else {
            EmptyStateView(icon: "person", title: "Person not found")
                .vividPageBackground()
        }
    }

    private func retry() {
        Task { await model.reload() }
    }

    private func open(_ item: BrowseItem) {
        router.navigate(to: Route.itemDetail(browseItem: item))
    }

    // MARK: Content

    #if os(iOS)
    private func personContent(_ person: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(person)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 16) {
                    filmographyHeader
                    filmographyState
                }
            }
            .padding(.bottom, VividTheme.largePadding)
        }
        .detailScrollDismissal()
        .vividPageBackground()
        .sheet(isPresented: $showsBiography) {
            NavigationStack {
                ScrollView {
                    Text(Self.biography(of: person) ?? "")
                        .font(.body)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .textSelection(.enabled)
                }
                .navigationTitle(person.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { VividSheetCloseItem { showsBiography = false } }
            }
            .vividGlassSheet()
        }
    }

    private func header(_ person: Person) -> some View {
        HStack(alignment: .top, spacing: 18) {
            PersonPortrait(person: person, width: VividTheme.posterCardWidth)
            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(3)
                FlowLayout(spacing: 6) {
                    ForEach(Self.badges(for: person), id: \.self) { badge in
                        PersonBadge(text: badge)
                    }
                    if model.isRefreshingMetadata {
                        MetadataRefreshIndicator()
                    }
                }
                if let bio = Self.biography(of: person) {
                    Text(bio)
                        .font(.vividBody)
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { showsBiography = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens the full biography")
                }
            }
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            filmographyTitleRow
                .padding(.horizontal, 16)
            filterBar
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var filmographyState: some View {
        if model.items.isEmpty && model.isLoadingFilmography {
            ProgressView()
                .tint(Color.vividOnSurface)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if model.items.isEmpty, let error = model.error {
            ErrorView(state: error, onRetry: retry)
                .frame(maxWidth: .infinity, minHeight: 260)
        } else if model.items.isEmpty {
            EmptyStateView(
                icon: "film",
                title: "No titles found",
                subtitle: "There are no movies or series linked to this person yet."
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            CatalogGrid(
                items: model.items,
                isLoading: model.isLoadingFilmography,
                hasMore: model.hasMore,
                forcesThreeColumnsOnPhone: true,
                onItemTap: open,
                onLoadMore: { Task { await model.loadMore() } }
            )
            .padding(.horizontal, 16)
        }
    }
    #else
    private func personContent(_ person: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header(person)
                    .padding(.horizontal, 80)
                    .padding(.top, 48)
                VStack(alignment: .leading, spacing: 28) {
                    filmographyHeader
                    filmographyState
                }
                .padding(.horizontal, 80)
            }
            .padding(.bottom, 72)
        }
        .vividPageBackground()
        .fullScreenCover(isPresented: $showsFullBiography) {
            TVFullSynopsis(overview: Self.biography(of: person) ?? "", title: String(localized: "Biography"))
                .presentationBackground(.clear)
        }
    }

    private func header(_ person: Person) -> some View {
        HStack(alignment: .top, spacing: 48) {
            PersonPortrait(person: person, width: VividTheme.Skyline.densePosterCardWidth)
            VStack(alignment: .leading, spacing: 22) {
                Text(person.name)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    ForEach(Self.badges(for: person), id: \.self) { badge in
                        PersonBadge(text: badge)
                    }
                    if model.isRefreshingMetadata {
                        MetadataRefreshIndicator()
                    }
                }
                if let bio = Self.biography(of: person) {
                    Button { showsFullBiography = true } label: {
                        Text(bio)
                            .font(.vividBody)
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(7)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 920, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TVSynopsisButtonStyle())
                    .accessibilityHint("Opens the full biography")
                }
            }
            .padding(.top, 10)
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            filmographyTitleRow
            filterBar
        }
    }

    @ViewBuilder
    private var filmographyState: some View {
        if model.items.isEmpty && model.isLoadingFilmography {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 420)
        } else if model.items.isEmpty, let error = model.error {
            ErrorView(state: error, onRetry: retry)
                .frame(maxWidth: .infinity, minHeight: 420)
        } else if model.items.isEmpty {
            EmptyStateView(
                icon: "film.stack",
                title: "No titles found",
                subtitle: "There are no movies or series linked to this person yet."
            )
            .frame(maxWidth: .infinity, minHeight: 420)
        } else {
            TVCatalogGrid(
                items: model.items,
                isLoading: model.isLoadingFilmography,
                hasMore: model.hasMore,
                onItemTap: open,
                onNearEnd: { index in Task { await model.nearEnd(at: index) } },
                columnCount: 8,
                cardWidth: VividTheme.Skyline.densePosterCardWidth
            )
        }
    }
    #endif

    private var filmographyTitleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Filmography")
                .font(.vividHeadline)
                .foregroundStyle(Color.vividOnSurface)
            if let count = filmographyCount {
                Text(count)
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
            }
            Spacer()
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.offeredFilters, id: \.self) { filter in
                    PersonFilterButton(
                        title: filter.title,
                        isSelected: filter == model.selectedFilter,
                        action: { Task { await model.applyFilter(filter) } }
                    )
                }
            }
            #if os(tvOS)
            .padding(.vertical, 8)
            #endif
        }
        .scrollClipDisabled()
    }

    private var filmographyCount: String? {
        if let total = model.total { return String(localized: "\(total) titles") }
        let loaded = model.items.count
        if loaded == 0 { return nil }
        return model.hasMore ? String(localized: "\(loaded)+ titles") : String(localized: "\(loaded) titles")
    }

    /// The biography without the blank lines servers often wrap it in, or
    /// nil when there is none.
    private static func biography(of person: Person) -> String? {
        guard let bio = person.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty else { return nil }
        return bio
    }

    /// Born, then Died or the current age, then the birthplace.
    private static func badges(for person: Person) -> [String] {
        var badges: [String] = []
        let birth = PersonDates.parse(person.birthDate)
        if let birth {
            badges.append(String(localized: "Born \(PersonDates.display(birth))"))
        }
        if let death = PersonDates.parse(person.deathDate) {
            badges.append(String(localized: "Died \(PersonDates.display(death))"))
        } else if let birth, let age = PersonDates.age(from: birth) {
            badges.append(String(localized: "\(age) years old"))
        }
        if let place = person.birthplace?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            badges.append(place)
        }
        return badges
    }
}

// MARK: - Pieces

private struct PersonPortrait: View {
    let person: Person
    let width: CGFloat

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
        ZStack {
            Color.vividSurfaceElevated
            if let url = person.photoUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: person.photoThumbhash,
                    targetSize: CGSize(width: width, height: height),
                    contentMode: .fill
                )
            } else {
                Text(initials)
                    .font(.system(size: width * 0.28, weight: .semibold))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// The first letters of the first two words, for people with no photo.
    private var initials: String {
        let letters = person.name.split(separator: " ").prefix(2).compactMap(\.first)
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
    }
}

private struct PersonBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.vividSmall)
            .foregroundStyle(Color.vividOnSurface)
            #if os(iOS)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            #else
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            #endif
            .background(Capsule().fill(Color.vividSurfaceVariant))
    }
}

/// Shown beside the badges while the server is still fetching the person.
private struct MetadataRefreshIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                #if os(iOS)
                .controlSize(.small)
                #else
                .controlSize(.regular)
                #endif
                .tint(Color.vividOnSurface)
            Text("Loading metadata")
                .font(.vividSmall)
                .foregroundStyle(Color.vividSecondaryText)
        }
        #if os(iOS)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        #else
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        #endif
        .background(Capsule().fill(Color.vividSurfaceVariant.opacity(0.72)))
        .accessibilityElement(children: .combine)
    }
}

private struct PersonFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.vividCaption)
                .foregroundStyle(isSelected || isFocused ? Color.vividOnSurface : Color.vividSecondaryText)
                #if os(iOS)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                #else
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                #endif
                .background(Capsule().fill(fill))
                .overlay(
                    Capsule().stroke(
                        isFocused ? Color.vividOnSurface.opacity(0.85) : Color.white.opacity(isSelected ? 0.16 : 0.08),
                        lineWidth: isFocused ? 2 : 1
                    )
                )
        }
        .buttonStyle(.vividFlat)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isSelected)
    }

    private var fill: Color {
        if isSelected { return .vividSurfaceVariant }
        if isFocused { return Color.vividSurfaceVariant.opacity(0.8) }
        return Color.vividSurfaceElevated.opacity(0.55)
    }
}
