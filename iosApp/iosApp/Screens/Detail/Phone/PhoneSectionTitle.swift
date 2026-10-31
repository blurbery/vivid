import SwiftUI

#if !os(tvOS)
/// A below-the-fold section title, with optional text on the trailing side
/// such as an episode count.
struct MobileSectionHeader: View {
    let title: Text
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                title
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.vividOnSurface)
            }
            Spacer(minLength: 8)
            if let trailing, !trailing.isEmpty {
                Text(verbatim: trailing)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
    }
}
#endif
