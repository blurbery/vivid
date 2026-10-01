import SwiftUI

/// Evaluates its content in its own view body, so the playback-time reads
/// inside (progress bar, time labels) redraw only this view on each tick
/// rather than the whole player controls that contain it.
struct PlayerTickIsolated<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
