import Foundation

extension SettingPresentation {
    /// `unsetLabel` in the app language. The generated contract keeps the
    /// English label, which other clients share.
    var displayUnsetLabel: String? {
        switch unsetLabel {
        case "Library default": String(localized: "Library default")
        case "No preference": String(localized: "No preference")
        case "None": String(localized: "None")
        default: unsetLabel
        }
    }
}
