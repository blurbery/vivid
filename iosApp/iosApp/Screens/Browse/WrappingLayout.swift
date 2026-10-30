import SwiftUI

/// Lays children out left to right at their ideal sizes, wrapping onto a new
/// line when the next one wouldn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let arrangement = arrange(subviews, availableWidth: availableWidth)
        return CGSize(width: min(arrangement.size.width, availableWidth), height: arrangement.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, availableWidth: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    /// Where each child goes, and the size of the whole.
    private func arrange(_ subviews: Subviews, availableWidth: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > availableWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return (origins, CGSize(width: max(widest, 0), height: y + lineHeight))
    }
}
