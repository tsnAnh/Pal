import PalDesign
import SwiftUI

enum MessageMenuMetrics {
    static let width: CGFloat = PlatformVariant.pick(mac: 205, iOS: 268)
    static let rowHeight: CGFloat = PlatformVariant.pick(mac: 30, iOS: 44)
    static let cellWidth: CGFloat = PlatformVariant.pick(mac: 32, iOS: 42)
    static let emojiSize: CGFloat = PlatformVariant.pick(mac: 17, iOS: 23)
    static let glyphSize: CGFloat = PlatformVariant.pick(mac: 12, iOS: 15)
    static let glyphWidth: CGFloat = PlatformVariant.pick(mac: 16, iOS: 22)
    static let textSize: CGFloat = PlatformVariant.pick(mac: 13, iOS: 16)
    static let radius: CGFloat = PlatformVariant.pick(mac: 12, iOS: 16)
}

struct MessageMenuSurface: ViewModifier {
    let identifier: String

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MessageMenuMetrics.radius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .padding(5)
            .palGlass(shape, interactive: false)
            .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

struct MessageMenuRow: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PalIcon(symbol, ink: .secondary)
                    .font(.system(size: MessageMenuMetrics.glyphSize))
                    .frame(width: MessageMenuMetrics.glyphWidth)
                Text(title)
                    .font(.system(size: MessageMenuMetrics.textSize))
                    .foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: MessageMenuMetrics.rowHeight)
            .background(hovering ? PalTokens.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macOnly { $0.onHover { hovering = $0 } }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

#if os(iOS)
struct MessageMenuRequest: Identifiable {
    let id = UUID()
    let anchor: CGRect
    let side: MessageSide
    let actions: MessageActions
}

private struct MessageMenuPresenterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MessageMenuRequest) -> Void)? = nil
}

extension EnvironmentValues {
    var presentMessageMenu: (@MainActor (MessageMenuRequest) -> Void)? {
        get { self[MessageMenuPresenterKey.self] }
        set { self[MessageMenuPresenterKey.self] = newValue }
    }
}

private struct MessageMenuPresenter: ViewModifier {
    @State private var request: MessageMenuRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.presentMessageMenu) { request = $0 }
            .overlay { MessageMenuHost(request: $request) }
    }
}

private struct MessageMenuHost: View {
    @Binding var request: MessageMenuRequest?

    var body: some View {
        GeometryReader { proxy in
            if let current = request {
                ZStack(alignment: .bottom) {
                    MessageSheetDim(anchor: current.anchor) { request = nil }
                        .transition(.opacity)
                    MessageSheet(actions: current.actions, maxContentHeight: proxy.size.height * 0.5) { request = nil }
                        .transition(.move(edge: .bottom))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.snappy(duration: 0.25), value: request?.id)
    }
}
#endif

extension View {
    func messageMenuPresenter() -> some View {
        #if os(iOS)
        modifier(MessageMenuPresenter())
        #else
        self
        #endif
    }
}
