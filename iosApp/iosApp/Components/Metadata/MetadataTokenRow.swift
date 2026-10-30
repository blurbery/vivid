import SwiftUI

#if os(iOS)
/// One line of metadata pills that drops tokens from the end until it fits,
/// always keeping the trailing content.
struct MetadataPillRow<Trailing: View>: View {
    let tokens: [String]
    @ViewBuilder var trailing: () -> Trailing

    init(tokens: [String], @ViewBuilder trailing: @escaping () -> Trailing) {
        self.tokens = tokens
        self.trailing = trailing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tokens.count, through: 0, by: -1)), id: \.self) { count in
                row(Array(tokens.prefix(count)))
            }
        }
    }

    private func row(_ shown: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, token in
                pill(token)
            }
            trailing()
        }
    }

    private func pill(_ token: String) -> some View {
        Text(verbatim: token)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vividOnSurface.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            )
    }
}

extension MetadataPillRow where Trailing == EmptyView {
    init(tokens: [String]) {
        self.init(tokens: tokens) { EmptyView() }
    }
}

/// A content rating such as M or PG-13 in a thin outlined box.
struct ContentRatingChip: View {
    let rating: String

    var body: some View {
        Text(verbatim: rating)
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(Color.vividOnSurface)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.vividOnSurface.opacity(0.55), lineWidth: 1))
    }
}
#endif
