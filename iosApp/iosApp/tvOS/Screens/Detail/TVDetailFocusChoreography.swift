#if os(tvOS)
import SwiftUI

/// Where focus sits for the scroll choreography, in order of precedence.
enum TVDetailFocusRegion: Equatable {
    case actionRow
    case moreLikeThis
    case seasonRow

    static func current(actionRow: Bool, moreLikeThis: Bool, seasonRow: Bool) -> TVDetailFocusRegion? {
        if actionRow { return .actionRow }
        if moreLikeThis { return .moreLikeThis }
        if seasonRow { return .seasonRow }
        return nil
    }
}

/// Scroll anchors the choreography moves to.
enum TVDetailScrollAnchor: Hashable {
    case hero
    case episodes
    case moreLikeThis
}

/// On the older layout and the season page, keeps the right part of the page
/// in view when focus enters the action row, the season chips or More Like
/// This. Each move repeats a few times so it outlasts the system's own
/// deferred reveal scrolls.
struct TVDetailFocusChoreography: ViewModifier {
    let proxy: ScrollViewProxy
    let region: TVDetailFocusRegion?

    @State private var generation = 0
    /// The region as of the latest change, read when a delayed move runs.
    @State private var latestRegion: TVDetailFocusRegion?

    private static let delays: [Double] = [0.02, 0.15, 0.45, 0.8, 1.1]

    func body(content: Content) -> some View {
        content
            .onChange(of: region) { _, newRegion in
                generation &+= 1
                latestRegion = newRegion
                guard let newRegion else { return }
                let started = generation
                let (anchorId, anchor) = Self.target(for: newRegion)
                for delay in Self.delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard generation == started, latestRegion == newRegion else { return }
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo(anchorId, anchor: anchor)
                        }
                    }
                }
            }
    }

    private static func target(for region: TVDetailFocusRegion) -> (TVDetailScrollAnchor, UnitPoint) {
        switch region {
        case .actionRow: (.hero, .top)
        case .moreLikeThis: (.moreLikeThis, .center)
        case .seasonRow: (.episodes, .center)
        }
    }
}
#endif
