#if !os(tvOS)
import SwiftUI

/// Editorial section header used below the phone hero — the same
/// pattern as `TVSectionHeader`, scaled to phones. A small tracked
/// all-caps "eyebrow" sits over the title only when it carries context
/// the title doesn't (e.g. "This Season" over "Episodes").
struct PhoneSectionHeader: View {
    private let label: Text?
    private let title: Text
    private let trailingText: Text?

    init(label: LocalizedStringKey? = nil, title: LocalizedStringKey, trailingText: LocalizedStringKey? = nil) {
        self.label = label.map { Text($0) }
        self.title = Text(title)
        self.trailingText = trailingText.map { Text($0) }
    }

    /// Shown verbatim, with empty strings hidden. Disfavoured so literals
    /// take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(label: String? = nil, title: S, trailingText: String? = nil) {
        self.label = label.flatMap { $0.isEmpty ? nil : Text($0) }
        self.title = Text(title)
        self.trailingText = trailingText.flatMap { $0.isEmpty ? nil : Text($0) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let label {
                    label
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(.vividOnSurface.opacity(0.55))
                        .textCase(.uppercase)
                }

                title
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.vividOnSurface)
            }

            Spacer(minLength: 8)

            if let trailingText {
                trailingText
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.vividSecondaryText)
            }
        }
    }
}
#endif
