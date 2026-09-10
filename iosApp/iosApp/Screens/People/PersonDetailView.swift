import SwiftUI
import os

enum PersonMediaFilter: String, CaseIterable, Identifiable {
    case all
    case movies
    case series

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .series: "Series"
        }
    }

    var catalogType: String? {
        switch self {
        case .all: nil
        case .movies: "movie"
        case .series: "series"
        }
    }
}

@Observable
@MainActor
final class PersonDetailViewModel {
    let personId: Int
    var person: Person?
    var items: [BrowseItem] = []
    var isLoadingPerson = false
    private var loadingItemsGeneration: Int?
    var isLoadingItems: Bool { loadingItemsGeneration == generation }
    var error: ErrorState?
    var hasMore = true
    var selectedFilter: PersonMediaFilter = .all
    var availableFilters = PersonMediaFilter.allCases
    var totalItems: Int?
    var isRefreshingMetadata = false

    private static let metadataRefreshWindowSeconds: TimeInterval = 120
    private static let metadataRefreshPollInterval: Duration = .seconds(3)
    /// Consecutive unchanged polls after which the person is treated as
    /// settled — the server refresh ran and this is all the metadata it has.
    private static let metadataRefreshSettledPollCount = 5
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "PersonDetail"
    )
    private let pageSize = 60
    private var nextOffset = 0
    private var snapshot: String?
    private var generation = 0
    private var metadataGeneration = 0
    private var metadataRefreshTask: Task<Void, Never>?
    private var autoRefreshRequestedPersonId: Int?
    private var metadataRefreshExhaustedPersonId: Int?

    #if os(tvOS)
    private var prefetchedPosterURLs: Set<URL> = []
    #endif

    private let requestPerson: (Int) async throws -> Person
    private let requestCatalog: (Int, String?, Int, Int, String?) async throws -> CatalogResponse

    init(
        personId: Int,
        requestPerson: @escaping (Int) async throws -> Person = { try await VividAPI.shared.person(id: $0) },
        requestCatalog: @escaping (Int, String?, Int, Int, String?) async throws -> CatalogResponse = {
            try await VividAPI.shared.personCatalogItems(personId: $0, type: $1, offset: $2, limit: $3, snapshot: $4)
        }
    ) {
        self.personId = personId
        self.requestPerson = requestPerson
        self.requestCatalog = requestCatalog
    }

    /// Cancel the manually-spawned refresh poll when this page leaves the
    /// nav stack. SwiftUI only auto-cancels `.task`; this task otherwise
    /// retains the view model and keeps mutating state after the route pops.
    func stopMetadataRefresh() {
        metadataGeneration += 1
        isLoadingPerson = false
        Self.logger.debug("stopMetadataRefresh personId=\(self.personId, privacy: .public)")
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        isRefreshingMetadata = false
    }

    func resumeMetadataRefreshIfNeeded() {
        scheduleMetadataRefreshIfNeeded(for: person)
    }

    var isInitialLoading: Bool {
        person == nil && (isLoadingPerson || isLoadingItems)
    }

    func loadInitial() async {
        guard person == nil, items.isEmpty, !isLoadingPerson, !isLoadingItems else { return }
        await reload()
    }

    func reload() async {
        stopMetadataRefresh()
        let currentMetadataGeneration = metadataGeneration
        generation += 1
        let currentGeneration = generation
        resetFilmography()
        error = nil

        if person == nil {
            person = ResponseCache.shared.get(CacheKey.person(personId))
        }
        async let metadata: Void = loadPerson(generation: currentMetadataGeneration)
        async let availability: Void = refreshAvailableFilters(generation: currentGeneration)
        await fetchPage(reset: true, generation: currentGeneration)
        await metadata
        await availability
    }

    private func loadPerson(generation currentGeneration: Int) async {
        guard !Task.isCancelled, currentGeneration == metadataGeneration else { return }
        isLoadingPerson = true
        defer {
            if currentGeneration == metadataGeneration { isLoadingPerson = false }
        }
        do {
            let updatedPerson = try await requestPerson(personId)
            guard !Task.isCancelled, currentGeneration == metadataGeneration else { return }
            person = updatedPerson
            ResponseCache.shared.set(updatedPerson, for: CacheKey.person(personId))
            scheduleMetadataRefreshIfNeeded(for: updatedPerson)
        } catch {
            guard !Task.isCancelled, currentGeneration == metadataGeneration else { return }
            if person == nil { self.error = ErrorState(error) }
        }
    }

    func applyFilter(_ filter: PersonMediaFilter) async {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        generation += 1
        let currentGeneration = generation
        resetFilmography()
        error = nil
        await fetchPage(reset: true, generation: currentGeneration)
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingItems else { return }
        await fetchPage(reset: false, generation: generation)
    }

    #if os(tvOS)
    func prefetchPosters(in range: Range<Int>) {
        let urls = items[safe: range]
            .compactMap(\.posterUrl)
            .compactMap(URL.init(string:))
        let newURLs = urls.filter { prefetchedPosterURLs.insert($0).inserted }
        guard !newURLs.isEmpty else { return }
        PosterImageCache.prefetchCardArtwork(newURLs)
    }
    #endif

    private func scheduleMetadataRefreshIfNeeded(for person: Person?) {
        guard let person else { return }
        guard person.isMetadataIncomplete else {
            metadataRefreshTask?.cancel()
            metadataRefreshTask = nil
            isRefreshingMetadata = false
            return
        }
        guard metadataRefreshTask == nil else { return }
        guard metadataRefreshExhaustedPersonId != person.id else { return }

        let shouldQueueRefresh = autoRefreshRequestedPersonId != person.id
        if shouldQueueRefresh {
            autoRefreshRequestedPersonId = person.id
        }
        isRefreshingMetadata = true
        Self.logger.debug("startMetadataRefresh personId=\(person.id, privacy: .public) queue=\(shouldQueueRefresh, privacy: .public)")
        let currentGeneration = metadataGeneration
        metadataRefreshTask = Task { [weak self] in
            await self?.runMetadataAutoRefresh(
                for: person.id,
                shouldQueueRefresh: shouldQueueRefresh,
                generation: currentGeneration
            )
        }
    }

    private func runMetadataAutoRefresh(for personId: Int, shouldQueueRefresh: Bool, generation currentGeneration: Int) async {
        defer {
            let wasCancelled = Task.isCancelled
            if currentGeneration == metadataGeneration {
                metadataRefreshTask = nil
                isRefreshingMetadata = false
                if !wasCancelled, person?.isMetadataIncomplete == true {
                    metadataRefreshExhaustedPersonId = personId
                }
            }
            Self.logger.debug("finishMetadataRefresh personId=\(personId, privacy: .public) cancelled=\(wasCancelled, privacy: .public)")
        }

        if shouldQueueRefresh,
           let token = await VividAPI.shared.currentAccessToken(),
           !token.isEmpty {
            _ = try? await VividAPI.shared.refreshPerson(id: personId)
        }

        let deadline = Date.now.addingTimeInterval(Self.metadataRefreshWindowSeconds)
        var unchangedPolls = 0
        while !Task.isCancelled && Date.now < deadline {
            do {
                try await Task.sleep(for: Self.metadataRefreshPollInterval)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                let updatedPerson = try await requestPerson(personId)
                guard !Task.isCancelled, currentGeneration == metadataGeneration, personId == self.personId else { return }
                ResponseCache.shared.set(updatedPerson, for: CacheKey.person(personId))
                if updatedPerson == person {
                    unchangedPolls += 1
                    if unchangedPolls >= Self.metadataRefreshSettledPollCount {
                        Self.logger.debug("settledMetadataRefresh personId=\(personId, privacy: .public)")
                        return
                    }
                    continue
                }
                unchangedPolls = 0
                person = updatedPerson
                if !updatedPerson.isMetadataIncomplete {
                    Self.logger.debug("completeMetadataRefresh personId=\(personId, privacy: .public)")
                    isRefreshingMetadata = false
                    return
                }
            } catch {
                continue
            }
        }
    }

    private func fetchPage(reset: Bool, generation currentGeneration: Int) async {
        guard !Task.isCancelled, currentGeneration == generation, hasMore, !isLoadingItems else { return }
        loadingItemsGeneration = currentGeneration
        defer {
            if loadingItemsGeneration == currentGeneration { loadingItemsGeneration = nil }
        }

        do {
            let response = try await requestCatalog(personId, selectedFilter.catalogType, nextOffset, pageSize, snapshot)
            guard !Task.isCancelled, currentGeneration == generation else { return }

            if reset {
                items = response.items
            } else {
                items.append(contentsOf: response.items)
            }
            totalItems = response.total
            hasMore = response.hasMore ?? false
            nextOffset += response.items.count
            if snapshot == nil { snapshot = response.snapshot }
        } catch {
            guard !Task.isCancelled, currentGeneration == generation else { return }
            self.error = ErrorState(error)
        }
    }

    private func refreshAvailableFilters(generation currentGeneration: Int) async {
        async let movies = catalogHasItems(type: "movie")
        async let series = catalogHasItems(type: "series")
        let results = await (movies, series)
        guard currentGeneration == generation else { return }

        var filters: [PersonMediaFilter] = [.all]
        if results.0 != false { filters.append(.movies) }
        if results.1 != false { filters.append(.series) }
        availableFilters = filters
    }

    /// `nil` means the availability check failed. In that case the filter
    /// remains visible rather than hiding content based on a network error.
    private func catalogHasItems(type: String) async -> Bool? {
        do {
            let response = try await requestCatalog(personId, type, 0, 1, nil)
            return !response.items.isEmpty || (response.total ?? 0) > 0
        } catch {
            return nil
        }
    }

    private func resetFilmography() {
        #if os(tvOS)
        if !prefetchedPosterURLs.isEmpty {
            PosterImageCache.stopPrefetchingCardArtwork(Array(prefetchedPosterURLs))
            prefetchedPosterURLs.removeAll()
        }
        #endif
        items = []
        totalItems = nil
        nextOffset = 0
        snapshot = nil
        hasMore = true
    }
}

struct PersonDetailView: View {
    @State private var viewModel: PersonDetailViewModel
    #if os(iOS)
    @Environment(\.detailPullBackAction) private var goBack
    @Environment(\.dismiss) private var dismiss
    #endif

    init(personId: Int) {
        _viewModel = State(initialValue: PersonDetailViewModel(personId: personId))
    }

    var body: some View {
        rootContent
            #if os(iOS)
            .environment(\.detailPullBackAction, {
                if let goBack { goBack() } else { dismiss() }
            })
            #endif
            .onAppear {
                viewModel.resumeMetadataRefreshIfNeeded()
            }
            .task {
                await viewModel.loadInitial()
            }
            .onDisappear {
                viewModel.stopMetadataRefresh()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let person = viewModel.person {
            personContent(person: person)
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
        } else if viewModel.isInitialLoading {
            ProgressView()
                .tint(.vividOnSurface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .vividPageBackground()
        } else {
            EmptyStateView(icon: "person", title: "Person not found")
                .vividPageBackground()
        }
    }

    @ViewBuilder
    private func personContent(person: Person) -> some View {
        #if os(tvOS)
        TVPersonDetailContent(person: person, viewModel: viewModel)
        #else
        #if os(iOS)
        // On iOS this pull means Back, including actor pages opened from
        // outside a title's detail sheet. Do not start a metadata refresh too.
        PhonePersonDetailContent(person: person, viewModel: viewModel)
        #else
        refreshablePersonContent(person: person)
        #endif
        #endif
    }

    #if !os(tvOS)
    private func refreshablePersonContent(person: Person) -> some View {
        PhonePersonDetailContent(person: person, viewModel: viewModel)
            .refreshable {
                async let overlayRefresh: Void = OverlayPrefsStore.shared.refresh()
                await viewModel.reload()
                await overlayRefresh
            }
    }
    #endif
}

#if os(tvOS)
private struct TVPersonDetailContent: View {
    let person: Person
    var viewModel: PersonDetailViewModel

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header
                    .padding(.horizontal, VividTheme.safePadding)
                    .padding(.top, 48)

                VStack(alignment: .leading, spacing: 28) {
                    filmographyHeader

                    if viewModel.items.isEmpty && viewModel.isLoadingItems {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if let error = viewModel.error, viewModel.items.isEmpty {
                        ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if viewModel.items.isEmpty {
                        EmptyStateView(
                            icon: "film.stack",
                            title: "No titles found",
                            subtitle: "There are no movies or series linked to this person yet."
                        )
                        .frame(maxWidth: .infinity, minHeight: 420)
                    } else {
                        TVCatalogGrid(
                            items: viewModel.items,
                            isLoading: viewModel.isLoadingItems,
                            hasMore: viewModel.hasMore,
                            onItemTap: { item in
                                router.navigate(to: .itemDetail(browseItem: item))
                            },
                            onNearEnd: { index in
                                Task { await viewModel.loadMoreIfNeeded() }
                                let end = min(index + 48, viewModel.items.count)
                                viewModel.prefetchPosters(in: index..<end)
                            },
                            columnCount: 8,
                            cardWidth: VividTheme.Skyline.densePosterCardWidth
                        )
                    }
                }
                .padding(.horizontal, VividTheme.safePadding)
            }
            .padding(.bottom, 72)
        }
        .vividPageBackground()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            PersonPortrait(person: person, width: VividTheme.Skyline.densePosterCardWidth)

            VStack(alignment: .leading, spacing: 22) {
                Text(person.name)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.vividOnSurface)
                    .lineLimit(2)

                metadataRow

                if let bio = clean(person.bio) {
                    Text(bio)
                        .font(.vividBody)
                        .foregroundColor(.vividSecondaryText)
                        .lineLimit(7)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 920, alignment: .leading)
                }
            }
            .padding(.top, 10)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            ForEach(metadataBadges, id: \.self) { badge in
                Text(badge)
                    .font(.vividSmall)
                    .foregroundColor(.vividOnSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.vividSurfaceVariant)
                    )
            }

            if viewModel.isRefreshingMetadata {
                PersonMetadataRefreshIndicator()
            }
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filmography")
                    .font(.vividHeadline)
                    .foregroundColor(.vividOnSurface)

                if let label = totalLabel {
                    Text(label)
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                }

                Spacer()
            }

            PersonFilterBar(filters: viewModel.availableFilters, selected: viewModel.selectedFilter) { filter in
                Task { await viewModel.applyFilter(filter) }
            }
        }
    }

    private var metadataBadges: [String] {
        person.personMetadataBadges
    }

    private var totalLabel: String? {
        personFilmographyCountLabel(total: viewModel.totalItems, loaded: viewModel.items.count, hasMore: viewModel.hasMore)
    }
}
#else
private struct PhonePersonDetailContent: View {
    let person: Person
    var viewModel: PersonDetailViewModel

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .padding(.horizontal, VividTheme.padding)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 16) {
                    filmographyHeader

                    if viewModel.items.isEmpty && viewModel.isLoadingItems {
                        ProgressView()
                            .tint(.vividOnSurface)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error = viewModel.error, viewModel.items.isEmpty {
                        ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if viewModel.items.isEmpty {
                        EmptyStateView(
                            icon: "film",
                            title: "No titles found",
                            subtitle: "There are no movies or series linked to this person yet."
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        CatalogGrid(
                            items: viewModel.items,
                            isLoading: viewModel.isLoadingItems,
                            hasMore: viewModel.hasMore,
                            forcesThreeColumnsOnPhone: true,
                            onItemTap: { item in
                                router.navigate(to: .itemDetail(browseItem: item))
                            },
                            onLoadMore: {
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                        )
                        .padding(.horizontal, VividTheme.padding)
                    }
                }
            }
            .padding(.bottom, VividTheme.largePadding)
        }
        .detailScrollDismissal()
        .vividPageBackground()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            PersonPortrait(person: person, width: VividTheme.posterCardWidth)

            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.vividOnSurface)
                    .lineLimit(3)

                metadataWrap

                if let bio = clean(person.bio) {
                    Text(bio)
                        .font(.vividBody)
                        .foregroundColor(.vividSecondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var metadataWrap: some View {
        FlowLayout(spacing: 6) {
            ForEach(person.personMetadataBadges, id: \.self) { badge in
                Text(badge)
                    .font(.vividSmall)
                    .foregroundColor(.vividOnSurface)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.vividSurfaceVariant)
                    )
            }

            if viewModel.isRefreshingMetadata {
                PersonMetadataRefreshIndicator()
            }
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filmography")
                    .font(.vividHeadline)
                    .foregroundColor(.vividOnSurface)

                if let label = personFilmographyCountLabel(
                    total: viewModel.totalItems,
                    loaded: viewModel.items.count,
                    hasMore: viewModel.hasMore
                ) {
                    Text(label)
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, VividTheme.padding)

            PersonFilterBar(filters: viewModel.availableFilters, selected: viewModel.selectedFilter) { filter in
                Task { await viewModel.applyFilter(filter) }
            }
            .padding(.horizontal, VividTheme.padding)
        }
    }
}
#endif

private struct PersonPortrait: View {
    let person: Person
    let width: CGFloat

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        ZStack {
            Color.vividSurfaceElevated

            if let photoUrl = clean(person.photoUrl) {
                AsyncImageView(
                    url: photoUrl,
                    thumbhash: person.photoThumbhash,
                    targetSize: CGSize(width: width, height: height),
                    contentMode: .fill
                )
            } else {
                Text(person.initials)
                    .font(.system(size: width * 0.28, weight: .semibold))
                    .foregroundColor(.vividSecondaryText)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct PersonMetadataRefreshIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(controlSize)
                .tint(.vividOnSurface)

            Text("Loading metadata")
                .font(.vividSmall)
                .foregroundColor(.vividSecondaryText)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(Color.vividSurfaceVariant.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
    }

    private var controlSize: ControlSize {
        #if os(tvOS)
        .regular
        #else
        .small
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        16
        #else
        9
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        8
        #else
        5
        #endif
    }
}

private struct PersonFilterBar: View {
    let filters: [PersonMediaFilter]
    let selected: PersonMediaFilter
    let onSelect: (PersonMediaFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    PersonFilterButton(
                        title: filter.title,
                        isSelected: filter == selected,
                        action: { onSelect(filter) }
                    )
                }
            }
            #if os(tvOS)
            .padding(.vertical, 8)
            #endif
        }
        .scrollClipDisabled()
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
                .font(buttonFont)
                .foregroundColor(foregroundColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule()
                        .stroke(strokeColor, lineWidth: isFocused ? 2 : 1)
                )
        }
        .buttonStyle(.vividFlat)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isSelected)
    }

    private var foregroundColor: Color {
        isSelected || isFocused ? .vividOnSurface : .vividSecondaryText
    }

    private var backgroundColor: Color {
        if isSelected { return .vividSurfaceVariant }
        if isFocused { return Color.vividSurfaceVariant.opacity(0.8) }
        return Color.vividSurfaceElevated.opacity(0.55)
    }

    private var strokeColor: Color {
        isFocused ? .vividOnSurface.opacity(0.85) : Color.white.opacity(isSelected ? 0.16 : 0.08)
    }

    private var buttonFont: Font {
        #if os(tvOS)
        .vividCaption
        #else
        .vividCaption
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        12
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        10
        #else
        7
        #endif
    }
}

private extension Person {
    var isMetadataIncomplete: Bool {
        clean(bio) == nil || clean(photoUrl) == nil || clean(birthDate) == nil
    }

    var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let value = String(parts).uppercased()
        return value.isEmpty ? "?" : value
    }

    var personMetadataBadges: [String] {
        var badges: [String] = []
        if let birthDate = formattedPersonDate(birthDate) {
            badges.append("Born \(birthDate)")
        }
        if let deathDate = formattedPersonDate(deathDate) {
            badges.append("Died \(deathDate)")
        } else if let age = personAge(from: birthDate, to: nil) {
            badges.append("\(age) years old")
        }
        if let birthplace = clean(birthplace) {
            badges.append(birthplace)
        }
        return badges
    }
}

private func personFilmographyCountLabel(total: Int?, loaded: Int, hasMore: Bool) -> String? {
    if let total {
        return total == 1 ? "1 title" : "\(total) titles"
    }
    guard loaded > 0 else { return nil }
    return hasMore ? "\(loaded)+ titles" : (loaded == 1 ? "1 title" : "\(loaded) titles")
}

private func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func formattedPersonDate(_ value: String?) -> String? {
    guard let date = parsePersonDate(value) else { return clean(value) }
    return SelfDateFormatter.personDisplay.string(from: date)
}

private func personAge(from birthValue: String?, to deathValue: String?) -> Int? {
    guard let birthDate = parsePersonDate(birthValue) else { return nil }
    let endDate = parsePersonDate(deathValue) ?? Date()
    let years = Calendar.current.dateComponents([.year], from: birthDate, to: endDate).year
    guard let years, years >= 0 else { return nil }
    return years
}

private func parsePersonDate(_ value: String?) -> Date? {
    guard let value = clean(value) else { return nil }
    return SelfDateFormatter.personISO.date(from: value)
}

private enum SelfDateFormatter {
    static let personISO: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let personDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#if os(tvOS)
private extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return [] }
        return self[lower..<upper]
    }
}
#endif
