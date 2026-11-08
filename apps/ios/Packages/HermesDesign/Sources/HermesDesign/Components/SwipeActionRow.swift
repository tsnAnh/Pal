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
            .opacity(offset < 0 ? 1 : 0)
            .accessibilityHidden(offset == 0)
            .accessibilityIdentifier("\(accessibilityIdentifier)-action")
            content
                .background(Color(theme.palette.groupedCard))
                .offset(x: offset)
                .simultaneousGesture(drag)
                .accessibilityAction(named: Text(actionTitle), action)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-Self.revealWidth, anchor + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projected = anchor + value.predictedEndTranslation.width
                withAnimation(.snappy(duration: 0.2)) {
                    let open = projected < -Self.revealWidth / 2
                    offset = open ? -Self.revealWidth : 0
                    anchor = offset
                }
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) {
            offset = 0
            anchor = 0
        }
    }
}
