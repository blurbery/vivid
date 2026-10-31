import SwiftUI

#if !os(tvOS)
/// One chip per season. The chosen one stays centred, and a long press
/// marks a whole season watched.
struct MobileSeasonChips: View {
    let seasons: [Season]
    let selectedSeason: Season?
    let onSelect: (Season) -> Void

    @State private var railWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        chip(season)
                            .id(season.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .onDuo { chips in
                    chips.frame(minWidth: PhoneDuo.usesWideLayout(horizontalSizeClass) ? railWidth : nil)
                }
            }
            .onDuo { rail in
                rail.onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    railWidth = width
                }
            }
            .onAppear {
                if let id = selectedSeason?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: selectedSeason?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: VividTheme.fastDuration)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func chip(_ season: Season) -> some View {
        let isSelected = season.id == selectedSeason?.id
        return Button {
            onSelect(season)
        } label: {
            Text(verbatim: Self.label(for: season))
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background {
                    if isSelected {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .modifier(SeasonWatchedContextMenu(season: season))
    }

    /// The season's own title, or Specials, or "Season 3".
    static func label(for season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return String(localized: "Specials") }
        return String(localized: "Season \(String(season.seasonNumber))")
    }
}
#endif
