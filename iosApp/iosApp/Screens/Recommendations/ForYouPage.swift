import SwiftUI

extension EnvironmentValues {
    /// The For You page tabs, handed to whichever list is showing so the tabs
    /// scroll with its content. Nil when the lists shouldn't draw them.
    @Entry var forYouPageTabs: AnyView? = nil
}

/// The three lists For You switches between.
enum ForYouList: String, CaseIterable, Hashable {
    case watchlist
    case favourites
    case collections

    var title: LocalizedStringKey {
        switch self {
        case .watchlist: "Watchlist"
        case .favourites: "Favourites"
        case .collections: "Collections"
        }
    }

    var filterChoices: PersonalListFilter.Choices {
        self == .collections ? .collections : .lists
    }
}

#if os(iOS)
/// The For You tab on iPhone and iPad: Watchlist, Favourites and Collections
/// switch in place under one row of page tabs, with a Filter menu beside them.
struct RecommendationsView: View {
    @State private var selection: ForYouList = .watchlist
    @State private var filters: [ForYouList: PersonalListFilter] = [:]
    @State private var chromeScroll = PageChromeScrollState()
    @Environment(\.usesDuoSideTabBar) private var usesDuoSideTabBar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        selectedList
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.forYouPageTabs, usesDuoSideTabBar ? nil : AnyView(pageTabs))
            .modifier(DuoBottomPageTabs(isActive: PhoneDuo.isDuo && usesDuoSideTabBar) { pageTabs })
            .environment(chromeScroll)
            .modifier(MobileTopScrollEdgeModifier())
            .background(VividAppBackdrop())
            .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var selectedList: some View {
        switch selection {
        case .watchlist:
            SavedTitlesList(kind: .watchlist, filter: filter(for: .watchlist))
        case .favourites:
            SavedTitlesList(kind: .favourites, filter: filter(for: .favourites))
        case .collections:
            ForYouCollectionsGrid(filter: filter(for: .collections))
        }
    }

    private func filter(for list: ForYouList) -> PersonalListFilter {
        (filters[list] ?? PersonalListFilter()).limited(to: list.filterChoices)
    }

    private var showsFilterMenu: Bool {
        !(selection == .collections && PersonalListFilter.Choices.collections.isEmpty)
    }

    private var selectedFilter: Binding<PersonalListFilter> {
        Binding(
            get: { filter(for: selection) },
            set: { value in
                filters[selection] = value
                chromeScroll.reset()
            }
        )
    }

    // MARK: Page tabs

    private var pageTabs: some View {
        HStack(spacing: 8) {
            segments
            if showsFilterMenu {
                filterMenu
            }
        }
        .onDuo { $0.frame(maxWidth: PhoneDuo.pageTabsMaxWidth(horizontalSizeClass)) }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(ForYouList.allCases, id: \.self) { list in
                let isSelected = list == selection
                Button {
                    selection = list
                    chromeScroll.reset()
                } label: {
                    Text(list.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .background(Capsule().fill(isSelected ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .vividGlass(in: Capsule())
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 520 : .infinity)
    }

    private var filterMenu: some View {
        let filter = filter(for: selection)
        return Menu {
            PersonalListFilterMenuContent(
                filter: selectedFilter,
                showsAlphabet: selection != .collections,
                choices: selection.filterChoices
            )
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 50, height: 50)
                .vividGlass(in: Circle())
                .overlay(alignment: .topTrailing) {
                    if filter.isActive {
                        Text("\(filter.activeCount)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.vividBackground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.vividOnSurface))
                    }
                }
        }
        .accessibilityLabel(filter.isActive ? Text("Filter, \(filter.activeCount) on") : Text("Filter"))
    }
}

/// On the iPhone Duo, when the tab bar sits in the strip beside the screen,
/// the page tabs move to the bottom of the page instead.
private struct DuoBottomPageTabs<Tabs: View>: ViewModifier {
    let isActive: Bool
    @ViewBuilder let tabs: () -> Tabs

    func body(content: Content) -> some View {
        if isActive {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                tabs().padding(.bottom, PhoneDuo.pageTabsBottomPadding)
            }
        } else {
            content
        }
    }
}
#else
/// Apple TV's For You lives in its own tab view. This exists so the shared
/// tab shell compiles, and draws nothing.
struct RecommendationsView: View {
    var body: some View {
        EmptyView()
    }
}
#endif
