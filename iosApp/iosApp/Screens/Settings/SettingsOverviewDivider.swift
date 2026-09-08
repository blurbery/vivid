#if os(iOS)
import SwiftUI

struct SettingsOverviewDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.vividDivider)
            .padding(.leading, 66)
    }
}
#endif
