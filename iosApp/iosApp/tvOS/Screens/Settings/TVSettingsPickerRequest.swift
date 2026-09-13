#if os(tvOS)
import SwiftUI

/// The choices and saved-value binding for a native Settings option menu.
struct TVSettingsPickerRequest: Identifiable {
    let id: String
    let title: String
    let options: [TVSettingsOption]
    let selection: Binding<String>
}
#endif
