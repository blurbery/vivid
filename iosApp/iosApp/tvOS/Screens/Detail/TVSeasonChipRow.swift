#if os(tvOS)
import SwiftUI

/// The season page's row of season chips, centred on the selected season.
struct TVSeasonChipRow: View {
    let seasons: [Season]
    let selectedSeasonId: String?
    let onSelect: (Season) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var focusedId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(seasons, id: \.contentId) { season in
                        Button {
                            onSelect(season)
                        } label: {
                            Text(verbatim: Self.title(for: season))
                                .font(.system(size: 20, weight: season.contentId == selectedSeasonId ? .semibold : .medium))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(TVSeasonChipStyle(isSelected: season.contentId == selectedSeasonId))
                        .focused($focusedId, equals: season.contentId)
                        .accessibilityAddTraits(season.contentId == selectedSeasonId ? .isSelected : [])
                        .modifier(SeasonWatchedContextMenu(season: season))
                        .id(season.contentId)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
            .modifier(TVSeasonChipDefaultFocus(focus: $focusedId, selectedId: selectedSeasonId))
            .onChange(of: selectedSeasonId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let selectedSeasonId {
                    proxy.scrollTo(selectedSeasonId, anchor: .center)
                }
            }
            .onChange(of: focusedId) { _, id in
                onFocusChange?(id != nil)
            }
        }
    }

    /// The season's own title first, then "Specials" or "Season N".
    static func title(for season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return String(localized: "Specials") }
        return String(localized: "Season \(String(season.seasonNumber))")
    }
}

private struct TVSeasonChipDefaultFocus: ViewModifier {
    var focus: FocusState<String?>.Binding
    let selectedId: String?

    func body(content: Content) -> some View {
        if let selectedId {
            content.defaultFocus(focus, selectedId, priority: .userInitiated)
        } else {
            content
        }
    }
}

private struct TVSeasonChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct TVSeasonChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    private var fill: Color {
        if isFocused { return .white }
        return .white.opacity(isSelected ? 0.20 : 0.05)
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(Capsule().fill(fill))
            .scaleEffect((isFocused ? 1.04 : 1) * (configuration.isPressed ? 0.97 : 1))
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}
#endif
