import PalDesign
import SwiftUI

struct KanbanFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

enum KanbanChipSize {
    case tile
    case header

    var textStyle: PalTextStyle { self == .tile ? .footnoteCaption : .chip }
    var iconSize: CGFloat { self == .tile ? 9 : 11 }
    var spacing: CGFloat { self == .tile ? 3 : 5 }
}

extension View {
    func kanbanChipFrame(_ size: KanbanChipSize, tileHeight: CGFloat? = nil) -> some View {
        modifier(KanbanChipFrame(size: size, tileHeight: tileHeight))
    }
}

private struct KanbanChipFrame: ViewModifier {
    let size: KanbanChipSize
    let tileHeight: CGFloat?

    func body(content: Content) -> some View {
        switch size {
        case .tile:
            content
                .padding(.horizontal, 7)
                .padding(.vertical, tileHeight == nil ? 3 : 0)
                .frame(height: tileHeight)
        case .header:
            content
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
    }
}
