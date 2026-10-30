import SwiftUI

/// Settings uses the selected app canvas on iOS and tvOS.
struct SettingsBackdrop: View {
    var body: some View {
        #if os(tvOS) || os(iOS)
        VividAppBackdrop()
        #endif
    }
}

#if os(tvOS)
/// One static canvas behind the app's changing navigation content. Full-screen
/// presentations reuse it because they are hosted outside the app container.
struct TVAppBackdrop: View {
    var body: some View {
        VividAppBackdrop()
    }
}
#endif
