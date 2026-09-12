import Foundation

#if os(tvOS)
import SwiftUI
#endif

func tvCustomizationMutationIsEnabled(
    allowsEditing: Bool,
    usesDeviceMenuOverride: Bool,
    changesFamilyMenu: Bool
) -> Bool {
    allowsEditing && (!changesFamilyMenu || !usesDeviceMenuOverride)
}

func tvLibrarySubtabLabel(_ name: String, isSeries: Bool) -> String {
    let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = isSeries ? #"(?:series|tv\s+shows?|shows?)"# : "movies?"
    let shortened = original.replacingOccurrences(
        of: "(?i)^" + prefix + #"[\s:–—_\-]+"#,
        with: "",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return shortened.isEmpty ? original : shortened
}
