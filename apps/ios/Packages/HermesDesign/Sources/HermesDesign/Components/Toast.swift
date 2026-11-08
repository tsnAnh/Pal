import SwiftUI

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let accessibilityIdentifier: String
    let duration: Duration

    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .hermesText(.rowTitle)
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .padding(.horizontal, 20)
                        .frame(height: HermesMetrics.pillHeight + 8)
                        .background(Color(theme.palette.glassCapsuleFill), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(message))
                        .accessibilityIdentifier(accessibilityIdentifier)
                        .task(id: message) {
                            try? await Task.sleep(for: duration)
                            if !Task.isCancelled { self.message = nil }
                        }
                }
            }
            .animation(.snappy(duration: 0.2), value: message)
    }
}

extension View {
    public func toast(_ message: Binding<String?>, accessibilityIdentifier: String = "toast", duration: Duration = .seconds(2)) -> some View {
        modifier(ToastModifier(message: message, accessibilityIdentifier: accessibilityIdentifier, duration: duration))
    }
}
