import SwiftUI

public struct LeadingBoundedLayout: Layout {
    public init() {}

    public static func boundedWidth(content: CGFloat, limit: CGFloat?) -> CGFloat {
        guard let limit else { return content }
        return min(content, limit)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        return CGSize(width: Self.boundedWidth(content: size.width, limit: proposal.width), height: size.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

public extension View {
    func boundedToColumn() -> some View {
        LeadingBoundedLayout { self }.clipped()
    }
}
