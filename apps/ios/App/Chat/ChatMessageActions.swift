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
    func messageActions(side: MessageSide, placement: MessageChromePlacement = .beside) -> some View {
        modifier(MessageActionsModifier(side: side, placement: placement))
    }
}

private struct MessageActionsModifier: ViewModifier {
    let side: MessageSide
    let placement: MessageChromePlacement

    @Environment(\.messageActions) private var actions

    private var badgeOffset: CGSize {
        placement == .insideBubble ? placement.badgeOffset : CGSize(width: side == .user ? -13 : 13, height: -21)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: side == .user ? .topLeading : .topTrailing) {
                if let reaction = actions?.reaction {
                    MessageReactionBadge(emoji: reaction)
                        .offset(badgeOffset)
                }
            }
            #if os(macOS)
            .modifier(MacMessageActionsModifier(side: side, placement: placement, actions: actions))
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

private struct SwipeDrag {
    var decision = SwipeReply.Decision.undecided
    var offset: CGFloat = 0
    var buzzed = false
}

private struct SwipeReplyGlyph: View {
    let progress: CGFloat

    var body: some View {
        GlassEffectContainer {
            PalIcon("arrow.uturn.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .palGlass(Circle(), interactive: false)
        }
        .padding(.leading, 8)
        .opacity(progress)
        .scaleEffect(0.6 + 0.4 * progress)
        .accessibilityHidden(true)
    }
}

private struct TouchMessageActions: ViewModifier {
    let side: MessageSide
    let actions: MessageActions?

    @Environment(\.presentMessageMenu) private var presentMenu
    @State private var frame = BubbleFrame()
    @State private var swipe = SwipeDrag()

    @MainActor
    private func open() {
        guard let actions, let presentMenu else { return }
        Haptics.impact()
        presentMenu(MessageMenuRequest(anchor: frame.rect, side: side, actions: actions))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: SwipeReply.minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                if swipe.decision == .undecided {
                    swipe.decision = SwipeReply.decide(startX: value.startLocation.x, translation: value.translation)
                }
                guard swipe.decision == .tracking else { return }
                let offset = SwipeReply.offset(for: value.translation.width)
                if swipe.offset != offset { swipe.offset = offset }
                if !swipe.buzzed, SwipeReply.reachedThreshold(value.translation.width) {
                    swipe.buzzed = true
                    Haptics.light()
                }
            }
            .onEnded { value in
                let shouldReply = swipe.decision == .tracking && SwipeReply.reachedThreshold(value.translation.width)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { swipe = SwipeDrag() }
                if shouldReply { actions?.reply() }
            }
    }

    func body(content: Content) -> some View {
        if let actions {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
                .offset(x: swipe.offset)
                .background(alignment: .leading) {
                    if swipe.decision == .tracking {
                        SwipeReplyGlyph(progress: SwipeReply.progress(for: swipe.offset))
                            .transition(.opacity)
                    }
                }
                .simultaneousGesture(swipeGesture, including: actions.isOwnFailed ? .subviews : .all)
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
