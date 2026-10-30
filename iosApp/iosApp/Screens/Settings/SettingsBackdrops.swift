import SwiftUI

/// The themed canvas behind settings pages.
struct SettingsBackdrop: View {
    var body: some View {
        VividAppBackdrop()
    }
}

#if os(tvOS)
/// The themed canvas behind Apple TV's top-level screens.
struct TVAppBackdrop: View {
    var body: some View {
        VividAppBackdrop()
    }
}
#endif
