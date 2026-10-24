#if os(tvOS)
import SwiftUI

/// Editorial section header used below the detail hero. No underline or
/// chrome — just a display title, with an optional small tracked all-caps
/// "eyebrow" above it, used only when the eyebrow carries context the
/// title doesn't (e.g. "This Season" over "Episodes").
struct TVSectionHeader: View {
    private let label: Text?
    private let title: Text

    init(label: LocalizedStringKey? = nil, title: LocalizedStringKey) {
        self.label = label.map { Text($0) }
        self.title = Text(title)
    }

    /// Shown verbatim, with an empty label hidden. Disfavoured so literals
    /// take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(label: String? = nil, title: S) {
        self.label = label.flatMap { $0.isEmpty ? nil : Text($0) }
        self.title = Text(title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label {
                label
                    .font(.system(size: 17, weight: .bold))
                    .tracking(3.0)
                    .foregroundColor(.vividOnSurface.opacity(0.55))
                    .textCase(.uppercase)
            }

            title
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.vividOnSurface)
        }
    }
}
#endif
