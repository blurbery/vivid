#if !os(tvOS)
import SwiftUI

/// Slim, squarish pill for one metadata fact (year, runtime, genre), shared
/// by the detail page and the home spotlight.
struct MetadataPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vividOnSurface.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            }
    }
}

/// One line of metadata pills that never wraps. When the line is too wide,
/// trailing pills (the last genre first) are left off until it fits. Any
/// trailing content, such as the age rating chip, always stays at the end.
struct MetadataPillRow<Trailing: View>: View {
    let tokens: [String]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tokens.count, through: tokens.isEmpty ? 0 : 1, by: -1)), id: \.self) { count in
                row(Array(tokens.prefix(count)))
            }
        }
    }

    private func row(_ visible: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, token in
                MetadataPill(text: token)
            }
            trailing()
        }
    }
}

extension MetadataPillRow where Trailing == EmptyView {
    init(tokens: [String]) {
        self.init(tokens: tokens) { EmptyView() }
    }
}

/// Outlined age rating chip (PG-13, TV-MA) shown beside the metadata on the
/// detail page and the home spotlight.
struct ContentRatingChip: View {
    let rating: String

    var body: some View {
        Text(rating)
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(Color.vividOnSurface)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.vividOnSurface.opacity(0.55), lineWidth: 1)
            )
    }
}
#endif
