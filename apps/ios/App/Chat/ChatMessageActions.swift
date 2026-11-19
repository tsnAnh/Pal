import PalChat
import PalDesign
import SwiftUI

enum MessageSide {
    case assistant
    case user
}

enum MessageReactions {
    static let choices = ReactionCatalog.quick
}

struct MessageActions: Sendable {
    let rowID: String
    let text: String
    let reaction: String?
    let ink: Color
    let canReact: @MainActor @Sendable () -> Bool
    let react: @MainActor @Sendable (String) -> Void
    let reply: @MainActor @Sendable () -> Void
    let isChatUnread: @MainActor @Sendable () -> Bool
    let toggleUnread: @MainActor @Sendable () -> Void
    let retry: (@MainActor @Sendable () -> Void)?
    let tables: @MainActor @Sendable () -> [MarkdownTable]

    var isOwnFailed: Bool { retry != nil }

    @MainActor
    func plan(offersSelectText: Bool) -> MessageActionPlan {
        MessageActionPlan(
            isOwnFailed: isOwnFailed,
            hasTable: !tables().isEmpty,
            isChatUnread: isChatUnread(),
            offersSelectText: offersSelectText
        )
    }
}

private struct MessageActionsKey: EnvironmentKey {
    static let defaultValue: MessageActions? = nil
}

extension EnvironmentValues {
    var messageActions: MessageActions? {
        get { self[MessageActionsKey.self] }
        set { self[MessageActionsKey.self] = newValue }
    }
}

extension View {
    func messageActions(side: MessageSide) -> some View {
        modifier(MessageActionsModifier(side: side))
    }
}

private struct MessageActionsModifier: ViewModifier {
    let side: MessageSide

    @Environment(\.messageActions) private var actions

    func body(content: Content) -> some View {
        content
            .overlay(alignment: side == .user ? .topLeading : .topTrailing) {
                if let reaction = actions?.reaction {
                    MessageReactionBadge(emoji: reaction)
                        .offset(x: side == .user ? -13 : 13, y: -21)
                }
            }
            #if os(macOS)
            .modifier(MacMessageActionsModifier(side: side, actions: actions))
            #else
            .modifier(TouchMessageActions(side: side, actions: actions))
            #endif
    }
}

#if os(iOS)
@MainActor
final class BubbleFrame {
    var rect = CGRect.zero
}

private struct TouchMessageActions: ViewModifier {
    let side: MessageSide
    let actions: MessageActions?

    @Environment(\.presentMessageMenu) private var presentMenu
    @State private var frame = BubbleFrame()

    @MainActor
    private func open() {
        guard let actions, let presentMenu else { return }
        Haptics.impact()
        presentMenu(MessageMenuRequest(anchor: frame.rect, side: side, actions: actions))
    }

    func body(content: Content) -> some View {
        if let actions {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
                .onLongPressGesture(minimumDuration: 0.35) { open() }
                .accessibilityAction(named: Text("Reply")) { actions.reply() }
                .accessibilityAction(named: Text("Copy")) { Pasteboard.string = actions.text }
                .accessibilityAction(named: Text("React")) { open() }
        } else {
            content
        }
    }
}
#endif

struct MessageReactionBadge: View {
    let emoji: String

    var body: some View {
        Text(emoji)
            .font(.system(size: 13))
            .frame(width: 24, height: 24)
            .background(PalTokens.elevated, in: Circle())
            .overlay(Circle().strokeBorder(PalTokens.panelBorder, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(emoji))
            .accessibilityIdentifier("messageReaction")
    }
}
