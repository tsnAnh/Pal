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
        OverflowScroll(axes) { content }
        #else
        content
        #endif
    }
}
