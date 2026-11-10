import SwiftUI

/// How a brand page's All in Your Library grid is narrowed and ordered, from
/// the filter menu beside its heading. It lasts while the page is open.
struct StudioNetworkLibraryFilter: Equatable {
    enum Show: CaseIterable {
        case all, movies, series

        var label: String {
            switch self {
            case .all: String(localized: "All")
            case .movies: String(localized: "Movies")
            case .series: String(localized: "TV Shows")
            }
        }

        func includes(_ item: BrowseItem) -> Bool {
            switch self {
            case .all: true
            case .movies: item.type == "movie"
            case .series: item.type == "series"
            }
        }
    }

    var show = Show.all
    /// One of the libraries' sort keys, newest added first to begin with.
    var sort = CatalogSortKey.addedAt
    var order = CatalogSortKey.addedAt.defaultOrder
    var genre: String?

    /// Sorts by `key` in its natural order, or flips the order when it's
    /// already the sort, as the libraries' Sort menu does.
    mutating func choose(_ key: CatalogSortKey) {
        if key == sort {
            order = order.flipped
        } else {
            sort = key
            order = key.defaultOrder
        }
    }

    /// Whether it hides any titles, so the menu's button can show it's in use.
    var isNarrowed: Bool { show != .all || genre != nil }

    /// The menu button's text.
    var label: String {
        guard let genre else { return show.label }
        // The app's shared "A · B" key, which every language keeps as it is.
        return String(localized: "\(show.label) · \(genre)")
    }

    /// Whether there are both movies and series to choose between.
    static func offersShow(in items: [BrowseItem]) -> Bool {
        items.contains { $0.type == "movie" } && items.contains { $0.type == "series" }
    }

    /// The genres of the titles `show` keeps, A to Z.
    func genres(in items: [BrowseItem]) -> [String] {
        Set(items.filter(show.includes).flatMap { $0.genres ?? [] })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Shows `option`, dropping a chosen genre none of its titles have, so
    /// the grid never empties.
    mutating func setShow(_ option: Show, in items: [BrowseItem]) {
        show = option
        if let genre, !genres(in: items).contains(genre) { self.genre = nil }
    }

    func apply(to items: [BrowseItem]) -> [BrowseItem] {
        let kept = items.filter { item in
            show.includes(item) && (genre.map { item.genres?.contains($0) == true } ?? true)
        }
        switch sort {
        case .title:
            return order == .asc ? kept.sorted(by: Self.titleOrder) : kept.sorted { Self.titleOrder($1, $0) }
        case .addedAt, .lastEpisodeReleased, .lastEpisodeAdded:
            // Brand pages don't offer the episode sorts.
            return sorted(kept, by: \.addedAt)
        case .releaseDate:
            // Emby and Jellyfin send a time after the date, Silo the date alone.
            return sorted(kept) { $0.releaseDate.map { String($0.prefix(10)) } ?? $0.year.map { String($0) } }
        case .year:
            return sorted(kept, by: \.year)
        case .runtime:
            return sorted(kept, by: \.runtime)
        case .resolution:
            return sorted(kept) { Self.resolutionHeight($0.overlaySummary?.resolution) }
        }
    }

    /// A resolution badge such as "2160p", "4K" or "SD" as a height in lines.
    static func resolutionHeight(_ badge: String?) -> Int? {
        guard let badge = badge?.lowercased().trimmingCharacters(in: .whitespaces), !badge.isEmpty else { return nil }
        if badge == "sd" { return 480 }
        if badge.hasSuffix("k"), let thousands = Int(badge.dropLast()) { return thousands * 540 }
        return Int(badge.prefix { $0.isNumber })
    }

    private static func titleOrder(_ lhs: BrowseItem, _ rhs: BrowseItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// Orders by `value` in the current order. Titles without a value go last
    /// in either order, and ties fall back to the title.
    private func sorted<Value: Comparable>(_ items: [BrowseItem], by value: (BrowseItem) -> Value?) -> [BrowseItem] {
        let ascending = order == .asc
        return items.sorted { lhs, rhs in
            switch (value(lhs), value(rhs)) {
            case let (left?, right?) where left != right: ascending ? left < right : left > right
            case (.some, nil): true
            case (nil, .some): false
            default: Self.titleOrder(lhs, rhs)
            }
        }
    }
}

/// The filter menu's choices, shared by iPhone, iPad and Apple TV.
struct StudioNetworkFilterMenuContent: View {
    @Binding var filter: StudioNetworkLibraryFilter
    let items: [BrowseItem]

    var body: some View {
        if StudioNetworkLibraryFilter.offersShow(in: items) {
            Section("Show") {
                ForEach(StudioNetworkLibraryFilter.Show.allCases, id: \.self) { option in
                    Button { filter.setShow(option, in: items) } label: { choice(option.label, isOn: option == filter.show) }
                }
            }
        }
        Menu("Sort") {
            ForEach(CatalogSortKey.available(for: .mixed), id: \.self) { key in
                Button { filter.choose(key) } label: { sortChoice(key) }
            }
        }
        let genres = filter.genres(in: items)
        if !genres.isEmpty {
            Menu("Genre") {
                Button { filter.genre = nil } label: { choice(String(localized: "All Genres"), isOn: filter.genre == nil) }
                ForEach(genres, id: \.self) { genre in
                    Button { filter.genre = genre } label: { choice(genre, isOn: filter.genre == genre) }
                }
            }
        }
    }

    @ViewBuilder
    private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Marks the current sort the way each platform's library Sort menu does.
    @ViewBuilder
    private func sortChoice(_ key: CatalogSortKey) -> some View {
        if key != filter.sort {
            Text(key.label)
        } else {
            #if os(tvOS)
            Label("\(key.label) · \(key.directionLabel(for: filter.order))", systemImage: "checkmark")
            #else
            Label(key.label, systemImage: filter.order == .asc ? "arrow.up" : "arrow.down")
            #endif
        }
    }
}
