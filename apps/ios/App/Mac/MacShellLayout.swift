#if os(macOS)
import PalDesign
import SwiftUI

struct MacShellLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let minimumHeight = subviews.map { $0.sizeThatFits(.zero).height }.max() ?? 0
        let idealHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(
            width: max(proposal.width ?? MacLayoutMetrics.windowMin, MacLayoutMetrics.windowMin),
            height: max(proposal.height ?? idealHeight, minimumHeight, MacLayoutMetrics.windowMinHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let allocation = MacLayoutMetrics.allocate(
            window: bounds.width,
            sidebar: subviews[0].sizeThatFits(.unspecified).width,
            inspectorRequested: subviews.count > 2
        )
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: allocation.sidebar, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + allocation.chatOriginX, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: allocation.chat, height: bounds.height)
        )
        if subviews.count > 2 {
            subviews[2].place(
                at: CGPoint(x: bounds.minX + allocation.inspectorOriginX, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: allocation.inspector, height: bounds.height)
            )
        }
    }
}
#endif
