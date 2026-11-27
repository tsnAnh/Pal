import SwiftUI

public struct OverflowScroll<Content: View>: View {
    private let axes: Axis.Set
    private let content: Content

    public init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: some View {
        ViewThatFits(in: axes) {
            content
            ScrollView(axes) { content }
                .scrollBounceBehavior(.basedOnSize, axes: axes)
        }
    }
}
