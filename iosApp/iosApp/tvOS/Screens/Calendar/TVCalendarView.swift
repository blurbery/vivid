#if os(tvOS)
import SwiftUI

/// The Apple TV Calendar root, laid out like For You: Upcoming and Trending
/// as sub-tabs, with the Calendar month button where For You keeps Filter and
/// A–Z. One scroll view holds both sub-tabs, so the tab row stays mounted and
/// keeps focus when the selection changes.
struct TVCalendarView: View {
    enum Page: String, CaseIterable { case upcoming = "Upcoming", trending = "Trending" }

    @Binding var page: Page
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    @State private var store = CalendarStore.shared
    @State private var tmdb = TVTMDbStore.shared
    @State private var showsMonth = false
    @State private var monthPick: Date?
    /// Trending narrowed to one day from its month view.
    @State private var trendingDay: Date?
    @State private var selectedTitle: TrendingTitle?
    @FocusState private var focusedTab: Page?
    @FocusState private var monthFocused: Bool
    @Environment(AppRouter.self) private var router

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 3)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    sectionTabs
                        .id("top")
                    switch page {
                    case .upcoming: upcoming
                    case .trending: trending
                    }
                }
                .padding(.bottom, 64)
            }
            .contentMargins(.top, 28, for: .scrollContent)
            .scrollClipDisabled()
            .modifier(TVPersonalScrollAppearance())
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 176)
        .task(id: "\(tmdb.contextKey):\(page.rawValue)") {
            switch page {
            case .upcoming: await store.loadUpcoming()
            case .trending: await store.loadTrending()
            }
        }
        .onChange(of: focusRequest) { _, request in
            if request > 0, !isTopMenuFocused { focusedTab = page }
        }
        .onAppear {
            if focusRequest > 0, !isTopMenuFocused { focusedTab = page }
        }
        .sheet(item: $selectedTitle) { title in
            TVTrendingTitleSheet(title: title)
        }
    }

    // MARK: Tab row

    private var sectionTabs: some View {
        HStack(spacing: 14) {
            ForEach(Page.allCases, id: \.self) { tab in
                let focused = focusedTab == tab
                Button {
                    page = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .foregroundStyle(focused ? Color.black : .white.opacity(page == tab ? 1 : 0.65))
                        .background(
                            focused ? Color.white : .white.opacity(page == tab ? 0.18 : 0.06),
                            in: Capsule()
                        )
                }
                .buttonStyle(.vividFlat)
                .focusEffectDisabled()
                .focused($focusedTab, equals: tab)
                .accessibilityAddTraits(page == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button { showsMonth = true } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .buttonStyle(TVBrowseControlPillStyle())
            .focused($monthFocused)
            .accessibilityHint(page == .upcoming ? "Shows the months ahead, to jump to a day" : "Shows the months ahead, to see what's coming out on a day")
        }
        .padding(.horizontal, VividTheme.safePadding)
        // As on For You: Up and Down between the row and the content are
        // native, and only Up to the top menu is a boundary hand-up.
        .defaultFocus($focusedTab, page, priority: .userInitiated)
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                monthFocused = false; focusedTab = nil; onTopMenuFocusRequest()
            }
        }
    }

    // MARK: Upcoming

    private var days: [(day: Date, episodes: [UpcomingEpisode])] {
        Dictionary(grouping: store.upcoming, by: \.day)
            .map { ($0.key, $0.value) }
            .sorted { $0.day < $1.day }
    }

    @ViewBuilder
    private var upcoming: some View {
        let days = days
        if days.isEmpty {
            if store.isLoadingUpcoming {
                ProgressView().frame(maxWidth: .infinity, minHeight: 360)
            } else {
                EmptyStateView(
                    icon: store.upcomingFailed ? "wifi.exclamationmark" : "calendar",
                    title: store.upcomingFailed ? "Couldn't load your calendar" : "Nothing airing soon",
                    subtitle: store.upcomingFailed ? "Try again in a moment." : "New episodes of shows in your Continue Watching, Watchlist and history appear here."
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .focusable()
            }
        } else {
            ForEach(days, id: \.day) { entry in
                VStack(alignment: .leading, spacing: 20) {
                    Text(TVCalendarView.dayTitle(entry.day))
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(Color.vividSecondaryText)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                        ForEach(entry.episodes) { episode in
                            Button { router.navigate(to: .itemDetail(contentId: episode.seriesContentId)) } label: {
                                TVUpcomingEpisodeCard(episode: episode)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, VividTheme.safePadding)
                .id(entry.day)
            }
            Text("Air times from TVmaze, shown in your time zone.")
                .font(.system(size: 20))
                .foregroundStyle(Color.vividSecondaryText)
                .frame(maxWidth: .infinity)
        }
    }

    /// "Today · Thursday 23 October", in the device's language and order.
    static func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today · \(date)".uppercased() }
        if calendar.isDateInTomorrow(day) { return "Tomorrow · \(date)".uppercased() }
        return date.uppercased()
    }

    // MARK: Trending

    @ViewBuilder
    private var trending: some View {
        if store.trendingSeries.isEmpty, store.trendingMovies.isEmpty {
            if store.isLoadingTrending {
                ProgressView().frame(maxWidth: .infinity, minHeight: 360)
            } else {
                EmptyStateView(
                    icon: store.trendingFailed ? "wifi.exclamationmark" : "sparkles",
                    title: store.trendingFailed ? "Couldn't load what's coming" : "Nothing coming soon",
                    subtitle: store.trendingFailed ? "Try again in a moment." : nil
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .focusable()
            }
        } else if let trendingDay {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(TVCalendarView.dayTitle(trendingDay))
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(Color.vividSecondaryText)
                    Spacer()
                    Button { self.trendingDay = nil } label: { Text("Show all") }
                        .buttonStyle(TVBrowseControlPillStyle())
                }
                let titles = (store.trendingSeries + store.trendingMovies).filter { $0.day == trendingDay }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 7), alignment: .leading, spacing: 48) {
                    ForEach(titles) { title in
                        TVTrendingPoster(title: title) { selectedTitle = title }
                    }
                }
            }
            .padding(.horizontal, VividTheme.safePadding)
        } else {
            trendingRail("New series coming soon", titles: store.trendingSeries)
            trendingRail("Movies coming soon", titles: store.trendingMovies)
            Text("From TMDb, most popular first.")
                .font(.system(size: 20))
                .foregroundStyle(Color.vividSecondaryText)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func trendingRail(_ heading: String, titles: [TrendingTitle]) -> some View {
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(heading)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, VividTheme.safePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(titles) { title in
                            TVTrendingPoster(title: title) { selectedTitle = title }
                                .frame(width: 220)
                        }
                    }
                    .padding(.horizontal, VividTheme.safePadding)
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: Month

    private var monthSheet: some View {
        let isUpcoming = page == .upcoming
        return TVCalendarMonthSheet(
            markedDays: Set(isUpcoming ? store.upcoming.map(\.day) : (store.trendingSeries + store.trendingMovies).map(\.day)),
            windowDays: isUpcoming ? CalendarStore.upcomingDays : CalendarStore.trendingDays,
            caption: isUpcoming
                ? "Dots mark days with new episodes. Choose one to jump to it."
                : "Dots mark days with releases. Choose one to see what's coming out.",
            markedValue: isUpcoming ? "New episodes" : "Releases"
        ) { day in
            monthPick = day
            showsMonth = false
        }
    }
}

// MARK: - Cards

private struct TVUpcomingEpisodeCard: View {
    let episode: UpcomingEpisode

    private var episodeLine: String {
        var parts: [String] = []
        if let season = episode.season { parts.append("S\(season)") }
        if let number = episode.number { parts.append("E\(number)") }
        if let name = episode.name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Color.vividSurfaceVariant
                if let url = episode.posterUrl, !url.isEmpty {
                    AsyncImageView(url: url, thumbhash: episode.posterThumbhash, targetSize: CGSize(width: 110, height: 165), contentMode: .fill)
                } else {
                    Image(systemName: "tv").foregroundStyle(Color.vividSecondaryText)
                }
            }
            .frame(width: 110, height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(episode.seriesTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let airsAt = episode.airsAt {
                        TVCalendarChip(text: airsAt.formatted(date: .omitted, time: .shortened))
                    }
                    if episode.isPremiere {
                        TVCalendarChip(text: "Premiere", tint: .vividBrandOrange)
                    }
                    TVCalendarChip(text: episode.source.label)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([episode.seriesTitle, episodeLine, episode.airsAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "", episode.source.label]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

private struct TVCalendarChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(tint ?? Color.white.opacity(0.85))
            .background((tint ?? .white).opacity(tint == nil ? 0.12 : 0.24), in: Capsule())
    }
}

/// Only the artwork is the card, as on Home's rows: the system's focus lift
/// and platter follow the poster, and the captions sit below it.
private struct TVTrendingPoster: View {
    let title: TrendingTitle
    let action: () -> Void

    var body: some View {
        // Room under the poster for the card's focus lift, so it never
        // covers the title.
        VStack(alignment: .leading, spacing: 20) {
            Button(action: action) { artwork }
                .buttonStyle(.card)
                .accessibilityLabel("\(title.title), \(title.kind == .movie ? "movie" : "series"), \(title.day.formatted(.dateTime.day().month(.wide)))")
            VStack(alignment: .leading, spacing: 4) {
                Text(title.title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(title.kind == .movie ? "Movie" : "Series")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
    }

    private var artwork: some View {
            ZStack(alignment: .topLeading) {
                Color.vividSurfaceVariant
                if let url = title.posterURL {
                    AsyncImageView(url: url.absoluteString, targetSize: CGSize(width: 220, height: 330), contentMode: .fill)
                }
                Text(title.day.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white, in: Capsule())
                    .padding(10)
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A Trending title's poster, date and overview. Menu closes it.
private struct TVTrendingTitleSheet: View {
    let title: TrendingTitle

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            ZStack {
                Color.vividSurfaceVariant
                if let url = title.posterURL {
                    AsyncImageView(url: url.absoluteString, targetSize: CGSize(width: 340, height: 510), contentMode: .fill)
                }
            }
            .frame(width: 340, height: 510)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                Text(title.title).font(.system(size: 52, weight: .bold)).foregroundStyle(.white)
                Text(title.kind == .movie ? "Movie" : "Series").font(.system(size: 26)).foregroundStyle(Color.vividSecondaryText)
                Text(title.kind == .movie ? "Out \(title.day.formatted(date: .long, time: .omitted))" : "Premieres \(title.day.formatted(date: .long, time: .omitted))")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                if let overview = title.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 26)).foregroundStyle(Color.vividOnSurface).padding(.top, 12)
                }
                Text("From TMDb.").font(.system(size: 20)).foregroundStyle(Color.vividSecondaryText)
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .focusable()
        }
        .padding(80)
    }
}

// MARK: - Month view

/// The months a Calendar page covers, with a dot on each day that has
/// something on it. Days with a dot and the month arrows are the focus
/// targets; choosing a day hands it back.
private struct TVCalendarMonthSheet: View {
    let markedDays: Set<Date>
    let windowDays: Int
    let caption: String
    /// What VoiceOver says for a day with a dot.
    let markedValue: String
    let onPick: (Date) -> Void

    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var firstMonth: Date { calendar.dateInterval(of: .month, for: today)?.start ?? today }
    private var lastMonth: Date {
        let end = calendar.date(byAdding: .day, value: windowDays, to: today) ?? today
        return calendar.dateInterval(of: .month, for: end)?.start ?? firstMonth
    }

    private var cells: [Date?] {
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading)
            + days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 40) {
                monthButton("chevron.left", label: "Previous month", enabled: month > firstMonth, by: -1)
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 420)
                monthButton("chevron.right", label: "Next month", enabled: month < lastMonth, by: 1)
            }
            .focusSection()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 16), count: 7), spacing: 12) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 80) }
                }
            }
            .focusSection()
            Text(caption)
                .font(.system(size: 22))
                .foregroundStyle(Color.vividSecondaryText)
        }
        .padding(60)
    }

    private func monthButton(_ symbol: String, label: String, enabled: Bool, by offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(TVBrowseControlPillStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let isToday = day == today
        let isMarked = markedDays.contains(day)
        let label = VStack(spacing: 6) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 30, weight: isToday || isMarked ? .semibold : .regular))
                .foregroundStyle(isMarked || isToday ? .white : Color.vividSecondaryText)
            Circle()
                .fill(isMarked ? Color.vividAccent : .clear)
                .frame(width: 8, height: 8)
        }
        .frame(width: 110, height: 80)
        .background(isToday ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(day < today ? 0.35 : 1)

        if isMarked {
            Button { onPick(day) } label: { label }
                .buttonStyle(.card)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(markedValue)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        }
    }

}
#endif
