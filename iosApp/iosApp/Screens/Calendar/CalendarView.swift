#if os(iOS)
import SwiftUI

/// The Calendar tab: Upcoming episodes of the profile's own series, and
/// popular movies and series coming soon from TMDb. Days and times are the
/// device's own, in its locale.
struct CalendarView: View {
    private enum Page: String, CaseIterable { case upcoming = "Upcoming", trending = "Trending" }
    private enum TrendingFilter: String, CaseIterable { case all = "All", movies = "Movies", series = "Series" }

    @State private var store = CalendarStore.shared
    @State private var tmdb = TVTMDbStore.shared
    @State private var page: Page = .upcoming
    @State private var trendingFilter: TrendingFilter = .all
    @State private var selectedTitle: TrendingTitle?
    @State private var showsMonth = false
    /// The day picked in the month view, used once it closes.
    @State private var monthPick: Date?
    /// Trending narrowed to one day from its month view.
    @State private var trendingDay: Date?
    /// Feeds the shared glass strip behind the status bar, as on For You.
    @State private var chromeScrollState = PageChromeScrollState()
    @Environment(AppRouter.self) private var router

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .id("top")
                    switch page {
                    case .upcoming: upcoming(proxy)
                    case .trending: trending
                    }
                }
                .frame(maxWidth: isPad ? 720 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .reportsPageChromeScroll()
            .sheet(isPresented: $showsMonth, onDismiss: {
                guard let day = monthPick else { return }
                monthPick = nil
                switch page {
                case .upcoming:
                    withAnimation { proxy.scrollTo(day, anchor: .top) }
                case .trending:
                    trendingDay = day
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                }
            }) {
                monthSheet
            }
        }
        .modifier(MobileTopScrollEdgeModifier())
        .environment(chromeScrollState)
        .background(VividAppBackdrop())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            switch page {
            case .upcoming: await store.loadUpcoming(force: true)
            case .trending: await store.loadTrending(force: true)
            }
        }
        .task(id: "\(tmdb.contextKey):\(page.rawValue)") {
            switch page {
            case .upcoming: await store.loadUpcoming()
            case .trending: await store.loadTrending()
            }
        }
        .sheet(item: $selectedTitle) { title in
            TrendingTitleSheet(title: title)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item; chromeScrollState.reset() } label: {
                        Text(item.rawValue).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(page == item ? Color.black : .white)
                            .background(page == item ? Color.white : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(5)
            .vividGlass(in: Capsule())
            .frame(maxWidth: isPad ? 520 : .infinity)
            Button {
                showsMonth = true
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .vividGlass(in: Circle())
            }
            .accessibilityLabel("Month")
            .accessibilityHint(page == .upcoming ? "Shows the months ahead, to jump to a day" : "Shows the months ahead, to see what's coming out on a day")
        }
    }

    /// Upcoming's month marks days with new episodes; Trending's marks
    /// release days for the titles its filter shows.
    private var monthSheet: some View {
        let isUpcoming = page == .upcoming
        return CalendarMonthSheet(
            markedDays: Set(isUpcoming ? store.upcoming.map(\.day) : trendingTitles.map(\.day)),
            windowDays: isUpcoming ? CalendarStore.upcomingDays : CalendarStore.trendingDays,
            caption: isUpcoming
                ? "Dots mark days with new episodes. Tap one to jump to it."
                : "Dots mark days with releases. Tap one to see what's coming out.",
            markedValue: isUpcoming ? "New episodes" : "Releases",
            unmarkedValue: isUpcoming ? "Nothing airing" : "Nothing coming out"
        ) { day in
            monthPick = day
            showsMonth = false
        }
    }

    // MARK: Upcoming

    private var days: [(day: Date, episodes: [UpcomingEpisode])] {
        Dictionary(grouping: store.upcoming, by: \.day)
            .map { ($0.key, $0.value) }
            .sorted { $0.day < $1.day }
    }

    @ViewBuilder
    private func upcoming(_ proxy: ScrollViewProxy) -> some View {
        let days = days
        weekStrip(days: Set(days.map(\.day)), proxy: proxy)
        if days.isEmpty {
            if store.isLoadingUpcoming {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 240)
            } else if store.upcomingFailed {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load your calendar", subtitle: "Pull down to try again.")
                    .frame(minHeight: 320)
            } else {
                EmptyStateView(
                    icon: "calendar",
                    title: "Nothing airing soon",
                    subtitle: "New episodes of shows in your Continue Watching, Watchlist and history appear here."
                )
                .frame(minHeight: 320)
            }
        } else {
            ForEach(days, id: \.day) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    Text(dayTitle(entry.day))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color.vividSecondaryText)
                        .padding(.top, 4)
                    ForEach(entry.episodes) { episode in
                        Button { router.navigate(to: .itemDetail(contentId: episode.seriesContentId)) } label: {
                            UpcomingEpisodeRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id(entry.day)
            }
            // TVmaze's licence asks for credit with a link back.
            Text("Air times from [TVmaze](https://www.tvmaze.com), shown in your time zone.")
                .font(.vividSmall)
                .foregroundStyle(Color.vividSecondaryText)
                .tint(Color.vividOnSurface)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    /// Two weeks from today. Days with an episode have a dot and scroll the
    /// list to that day.
    private func weekStrip(days: Set<Date>, proxy: ScrollViewProxy) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        let dates = (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(dates, id: \.self) { date in
                    let hasEpisodes = days.contains(date)
                    Button {
                        guard hasEpisodes else { return }
                        withAnimation { proxy.scrollTo(date, anchor: .top) }
                    } label: {
                        VStack(spacing: 4) {
                            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.vividSecondaryText)
                            Text(date.formatted(.dateTime.day()))
                                .font(.system(size: 17, weight: date == today ? .semibold : .regular))
                                .foregroundStyle(date == today ? Color.black : (hasEpisodes ? .white : Color.vividSecondaryText))
                                .frame(width: 34, height: 34)
                                .background(date == today ? Color.white : .clear, in: Circle())
                            Circle()
                                .fill(hasEpisodes ? Color.vividAccent : .clear)
                                .frame(width: 5, height: 5)
                        }
                        .containerRelativeFrame(.horizontal, count: 7, spacing: 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .accessibilityValue(hasEpisodes ? "New episodes" : "Nothing airing")
                }
            }
        }
        .scrollTargetBehavior(.paging)
    }

    /// "Today · Thursday 23 October", in the device's language and order.
    private func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today · \(date)".uppercased() }
        if calendar.isDateInTomorrow(day) { return "Tomorrow · \(date)".uppercased() }
        return date.uppercased()
    }

    // MARK: Trending

    @ViewBuilder
    private var trending: some View {
        HStack(spacing: 6) {
            ForEach(TrendingFilter.allCases, id: \.self) { filter in
                Button { trendingFilter = filter } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(trendingFilter == filter ? Color.black : .white)
                        .background(trendingFilter == filter ? Color.white : Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(trendingFilter == filter ? .isSelected : [])
            }
        }
        if store.trendingSeries.isEmpty, store.trendingMovies.isEmpty {
            if store.isLoadingTrending {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 240)
            } else {
                EmptyStateView(
                    icon: store.trendingFailed ? "wifi.exclamationmark" : "sparkles",
                    title: store.trendingFailed ? "Couldn't load what's coming" : "Nothing coming soon",
                    subtitle: store.trendingFailed ? "Pull down to try again." : nil
                )
                .frame(minHeight: 320)
            }
        } else if let trendingDay {
            HStack {
                Text(dayTitle(trendingDay))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.vividSecondaryText)
                Spacer()
                Button { self.trendingDay = nil } label: {
                    Text("Show all")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            let titles = trendingTitles.filter { $0.day == trendingDay }
            if titles.isEmpty {
                EmptyStateView(icon: "calendar", title: "Nothing coming out that day", subtitle: "Choose another day or show all.")
                    .frame(minHeight: 320)
            } else {
                trendingGrid(titles)
            }
        } else {
            switch trendingFilter {
            case .all:
                trendingRail("New series coming soon", titles: store.trendingSeries)
                trendingRail("Movies coming soon", titles: store.trendingMovies)
            case .movies:
                filteredTrending(store.trendingMovies, failed: store.trendingMoviesFailed)
            case .series:
                filteredTrending(store.trendingSeries, failed: store.trendingSeriesFailed)
            }
            Text("From TMDb, most popular first.")
                .font(.vividSmall)
                .foregroundStyle(Color.vividSecondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    /// One filter's grid. Its list can be empty while the other has titles,
    /// or failed to load on its own.
    @ViewBuilder
    private func filteredTrending(_ titles: [TrendingTitle], failed: Bool) -> some View {
        if titles.isEmpty {
            EmptyStateView(
                icon: failed ? "wifi.exclamationmark" : "sparkles",
                title: failed ? "Couldn't load what's coming" : "Nothing coming soon",
                subtitle: failed ? "Pull down to try again." : nil
            )
            .frame(minHeight: 320)
        } else {
            trendingGrid(titles)
        }
    }

    /// The titles the Trending filter shows.
    private var trendingTitles: [TrendingTitle] {
        switch trendingFilter {
        case .all: store.trendingSeries + store.trendingMovies
        case .movies: store.trendingMovies
        case .series: store.trendingSeries
        }
    }

    @ViewBuilder
    private func trendingRail(_ heading: String, titles: [TrendingTitle]) -> some View {
        if !titles.isEmpty {
            Text(heading).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(titles) { title in
                        Button { selectedTitle = title } label: { TrendingPoster(title: title, width: 110) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func trendingGrid(_ titles: [TrendingTitle]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: isPad ? 5 : 3), spacing: 16) {
            ForEach(titles) { title in
                Button { selectedTitle = title } label: { TrendingPoster(title: title, width: nil) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Month view

/// The months a Calendar page covers, with a dot on each day that has
/// something on it. Picking one of those days hands it back.
private struct CalendarMonthSheet: View {
    let markedDays: Set<Date>
    /// How many days ahead the page looks, which sets the last month.
    let windowDays: Int
    let caption: String
    /// What VoiceOver says for a day with and without a dot.
    let markedValue: String
    let unmarkedValue: String
    let onPick: (Date) -> Void

    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @Environment(\.dismiss) private var dismiss

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var firstMonth: Date { calendar.dateInterval(of: .month, for: today)?.start ?? today }
    /// The month the page's window ends in.
    private var lastMonth: Date {
        let end = calendar.date(byAdding: .day, value: windowDays, to: today) ?? today
        return calendar.dateInterval(of: .month, for: end)?.start ?? firstMonth
    }

    /// The month's days, after blanks for the days before the 1st in the
    /// device's own first weekday.
    private var cells: [Date?] {
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading)
            + days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        NavigationStack {
            // The month and its arrows live in the bar, so a six-row month
            // scrolls under them instead of pushing into the close button.
            ScrollView {
                VStack(spacing: 14) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.vividSecondaryText)
                        }
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                            if let day { dayCell(day) } else { Color.clear.frame(height: 42) }
                        }
                    }
                    Text(caption)
                        .font(.vividSmall)
                        .foregroundStyle(Color.vividSecondaryText)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
            .vividNavigationTitleDisplayMode(.inline)
            .toolbar {
                VividSheetCloseItem { dismiss() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    monthButton("chevron.left", label: "Previous month", enabled: month > firstMonth, by: -1)
                    monthButton("chevron.right", label: "Next month", enabled: month < lastMonth, by: 1)
                }
            }
        }
        .vividGlassSheet()
    }

    private func monthButton(_ symbol: String, label: String, enabled: Bool, by offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
        } label: {
            Image(systemName: symbol)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = day == today
        let hasEpisodes = markedDays.contains(day)
        let isPast = day < today
        return Button {
            guard hasEpisodes else { return }
            onPick(day)
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: isToday || hasEpisodes ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.black : (hasEpisodes ? .white : Color.vividSecondaryText))
                    .frame(width: 34, height: 34)
                    .background(isToday ? Color.white : .clear, in: Circle())
                Circle()
                    .fill(hasEpisodes ? Color.vividAccent : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .opacity(isPast ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(hasEpisodes ? markedValue : unmarkedValue)
    }
}

// MARK: - Rows and posters

private struct UpcomingEpisodeRow: View {
    let episode: UpcomingEpisode

    private var episodeLine: String {
        var parts: [String] = []
        if let season = episode.season { parts.append("S\(season)") }
        if let number = episode.number { parts.append("E\(number)") }
        if let name = episode.name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            poster
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.seriesTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let airsAt = episode.airsAt {
                        CalendarChip(text: airsAt.formatted(date: .omitted, time: .shortened))
                    }
                    if episode.isPremiere {
                        CalendarChip(text: "Premiere", tint: .vividBrandOrange)
                    }
                    CalendarChip(text: episode.source.label)
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var poster: some View {
        ZStack {
            Color.vividSurfaceVariant
            if let url = episode.posterUrl, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: episode.posterThumbhash, targetSize: CGSize(width: 48, height: 72), contentMode: .fill)
            } else {
                Image(systemName: "tv").foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: 48, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var accessibilityText: String {
        var parts = [episode.seriesTitle, episodeLine]
        if let airsAt = episode.airsAt { parts.append(airsAt.formatted(date: .omitted, time: .shortened)) }
        if episode.isPremiere { parts.append("Premiere") }
        parts.append(episode.source.label)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct CalendarChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint.map { $0.opacity(0.95) } ?? Color.white.opacity(0.8))
            .background((tint ?? .white).opacity(tint == nil ? 0.1 : 0.22), in: Capsule())
    }
}

private struct TrendingPoster: View {
    let title: TrendingTitle
    /// Nil fills a grid column.
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Color.vividSurfaceVariant
                if let url = title.posterURL {
                    AsyncImageView(url: url.absoluteString, targetSize: CGSize(width: width ?? 120, height: (width ?? 120) * 1.5), contentMode: .fill)
                }
                Text(title.day.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white, in: Capsule())
                    .padding(6)
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(title.kind == .movie ? "Movie" : "Series")
                .font(.system(size: 11))
                .foregroundStyle(Color.vividSecondaryText)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.title), \(title.kind == .movie ? "movie" : "series"), \(title.day.formatted(.dateTime.day().month(.wide)))")
    }
}

/// A Trending title's poster, date and overview. Most aren't out yet, so
/// they aren't in the library to open.
private struct TrendingTitleSheet: View {
    let title: TrendingTitle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            Color.vividSurfaceVariant
                            if let url = title.posterURL {
                                AsyncImageView(url: url.absoluteString, targetSize: CGSize(width: 120, height: 180), contentMode: .fill)
                            }
                        }
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                            Text(title.kind == .movie ? "Movie" : "Series").foregroundStyle(Color.vividSecondaryText)
                            Text(title.kind == .movie ? "Out \(title.day.formatted(date: .long, time: .omitted))" : "Premieres \(title.day.formatted(date: .long, time: .omitted))")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    if let overview = title.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 15)).foregroundStyle(Color.vividOnSurface)
                    }
                    Text("From TMDb.").font(.vividSmall).foregroundStyle(Color.vividSecondaryText)
                }
                .padding(20)
            }
            .toolbar { VividSheetCloseItem { dismiss() } }
        }
        .vividGlassSheet()
    }
}
#endif
