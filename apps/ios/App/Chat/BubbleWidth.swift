import HermesDesign
import SwiftUI

#if os(iOS)
private struct FractionalWidthLayout: Layout {
    let fraction: CGFloat
    let alignment: HorizontalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let column = proposal.width
        let size = subview.sizeThatFits(ProposedViewSize(width: column.map { $0 * fraction }, height: proposal.height))
        return CGSize(width: column ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: proposal.height))
        let x = alignment == .trailing ? bounds.maxX - size.width : bounds.minX
        subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
#endif

extension View {
    @ViewBuilder
    func bubbleWidth(_ alignment: HorizontalAlignment) -> some View {
        #if os(macOS)
        frame(maxWidth: ChatMetrics.bubbleMaxWidth).frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        #else
        FractionalWidthLayout(fraction: ChatMetrics.bubbleWidthFraction, alignment: alignment) { self }
        #endif
    }
}
