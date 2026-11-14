import SwiftUI

public enum LoadingPolicy {
    public static let silentWindow: Duration = .seconds(5)
}

public struct DelayedReveal<Content: View>: View {
    private let delay: Duration
    private let content: Content
    @State private var visible = false

    public init(after delay: Duration = LoadingPolicy.silentWindow, @ViewBuilder content: () -> Content) {
        self.delay = delay
        self.content = content()
    }

    public var body: some View {
        ZStack {
            if visible {
                content
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 1, minHeight: 1)
        .accessibilityElement(children: .contain)
        .animation(.easeIn(duration: 0.2), value: visible)
        .task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { visible = true }
        }
    }
}

public struct DelayedProgressView: View {
    private let delay: Duration

    public init(after delay: Duration = LoadingPolicy.silentWindow) {
        self.delay = delay
    }

    public var body: some View {
        DelayedReveal(after: delay) { ProgressView() }
    }
}
