import SwiftUI

private struct ReportColumnKey: LayoutValueKey {
    static let defaultValue = 0
}

extension View {
    func reportColumn(_ column: Int) -> some View {
        layoutValue(key: ReportColumnKey.self, value: column)
    }
}

/// Explicit columns keep sections predictable as findings expand or disappear.
/// One child hierarchy preserves chart selections and search state across resizing.
struct SpendingDashboardLayout: Layout {
    var allowsColumns: Bool
    private let gap: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 1080
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let twoColumns = allowsColumns && width >= 940
        let leadingWidth = twoColumns ? (width - gap) * 0.55 : width
        let trailingWidth = twoColumns ? width - gap - leadingWidth : width
        var bottoms: [CGFloat] = [0, 0]
        return subviews.map { subview in
            let column = twoColumns ? min(1, max(0, subview[ReportColumnKey.self])) : 0
            let cardWidth = column == 0 ? leadingWidth : trailingWidth
            let height = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            let frame = CGRect(x: column == 0 ? 0 : leadingWidth + gap, y: bottoms[column], width: cardWidth, height: height)
            bottoms[column] = frame.maxY + gap
            return frame
        }
    }
}
