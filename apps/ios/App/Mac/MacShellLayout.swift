#if os(macOS)
import PalDesign
import PalDiagnostics
import SwiftUI

struct MacShellLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        PalPerf.event("shell.layout.size")
        return CGSize(
            width: max(proposal.width ?? MacLayoutMetrics.windowMin, MacLayoutMetrics.windowMin),
            height: max(proposal.height ?? MacLayoutMetrics.windowMinHeight, MacLayoutMetrics.windowMinHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        PalPerf.event("shell.layout.place")
        let allocation = MacLayoutMetrics.allocate(
            window: bounds.width,
            sidebar: subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width,
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
