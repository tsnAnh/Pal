import SwiftUI

public struct MacOverflowScroll<Content: View>: View {
    private let axes: Axis.Set
    private let content: Content

    public init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
        ViewThatFits(in: axes) {
            content
            ScrollView(axes) { content }
                .scrollBounceBehavior(.basedOnSize, axes: axes)
        }
        #else
        content
        #endif
    }
}
