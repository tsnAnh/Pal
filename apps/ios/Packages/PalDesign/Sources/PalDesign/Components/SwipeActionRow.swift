import SwiftUI

public struct SwipeActionRow<Content: View>: View {
    public let actionTitle: String
    public let accessibilityIdentifier: String
    public let action: () -> Void
    private let content: Content

    @Environment(\.hermesTheme) private var theme
    @State private var offset: CGFloat = 0
    @State private var anchor: CGFloat = 0

    private static var revealWidth: CGFloat { 92 }

    public init(
        actionTitle: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.actionTitle = actionTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button {
                    close()
                    action()
                } label: {
                    Text(actionTitle)
                        .hermesText(.rowTitle)
                        .foregroundStyle(Color(theme.palette.chipSelectedText))
                        .frame(width: Self.revealWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color(theme.palette.destructive))
                }
                .buttonStyle(.plain)
            }
            content
                .background(Color(theme.palette.groupedCard))
                .offset(x: offset)
                #if os(iOS)
                .gesture(pan)
                #else
                .simultaneousGesture(drag)
                #endif
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: Text(actionTitle), action)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    #if !os(iOS)
    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-Self.revealWidth, anchor + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                settle(projected: anchor + value.predictedEndTranslation.width)
            }
    }
    #endif

    #if os(iOS)
    private var pan: ScrollSafePan {
        ScrollSafePan { _, velocity in
            abs(velocity.width) > abs(velocity.height)
        } update: { phase in
            switch phase {
            case .changed(let sample):
                offset = min(0, max(-Self.revealWidth, anchor + sample.translation.width))
            case .ended(let sample):
                settle(projected: anchor + sample.translation.width + sample.velocity.width * Self.projectionSeconds)
            case .cancelled:
                settle(projected: anchor)
            }
        }
    }

    private static var projectionSeconds: CGFloat { 0.2 }
    #endif

    private func settle(projected: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            let open = projected < -Self.revealWidth / 2
            offset = open ? -Self.revealWidth : 0
            anchor = offset
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) {
            offset = 0
            anchor = 0
        }
    }
}
