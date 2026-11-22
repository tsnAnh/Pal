#if os(macOS)
import PalDesign
import PalDiagnostics
import SwiftUI

enum MessageBarControl: Hashable {
    case react
    case reply
    case more
}

private struct BarAccessibilityActions: ViewModifier {
    let react: (() -> Void)?
    let reply: (() -> Void)?
    let more: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("More"), more)
            .modifier(OptionalAccessibilityAction(name: "React", action: react))
            .modifier(OptionalAccessibilityAction(name: "Reply", action: reply))
    }
}

private struct OptionalAccessibilityAction: ViewModifier {
    let name: LocalizedStringKey
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: Text(name), action)
        } else {
            content
        }
    }
}

struct MessageBarLayout: Equatable {
    static let pitch: CGFloat = 25
    static let height: CGFloat = 26

    let isOwnFailed: Bool
    let canReact: Bool

    var showsReact: Bool { !isOwnFailed && canReact }
    var showsReply: Bool { !isOwnFailed }

    var size: CGSize {
        let buttons = (showsReact ? 1 : 0) + (showsReply ? 1 : 0) + 1
        return CGSize(width: Self.pitch * CGFloat(buttons), height: Self.height)
    }
}

struct MacMessageHoverBar: View {
    let actions: MessageActions
    let layout: MessageBarLayout
    let visible: Bool
    var focus: FocusState<MessageBarControl?>.Binding

    @Environment(MacShell.self) private var shell
    @Environment(\.rowHover) private var rowHover
    @State private var reactFrame = CGRect.zero
    @State private var moreFrame = CGRect.zero

    var body: some View {
        let showsReact = layout.showsReact
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 0) {
                if showsReact {
                    Button { openMenu(from: reactFrame) } label: { glyph("face.smiling") }
                        .buttonStyle(.plain)
                        .focused(focus, equals: .react)
                        .background { measure(visible, into: $reactFrame) }
                        .help(String(localized: "React"))
                        .accessibilityLabel(Text("React"))
                        .accessibilityIdentifier("messageReact")
                }
                if layout.showsReply {
                    Button { actions.reply() } label: { glyph("arrow.uturn.left") }
                        .buttonStyle(.plain)
                        .focused(focus, equals: .reply)
                        .help(String(localized: "Reply"))
                        .accessibilityLabel(Text("Reply"))
                        .accessibilityIdentifier("messageReply")
                }
                Button { openMenu(from: moreFrame) } label: { glyph("ellipsis") }
                    .buttonStyle(.plain)
                    .focused(focus, equals: .more)
                    .background { measure(visible, into: $moreFrame) }
                    .help(String(localized: "More"))
                    .accessibilityLabel(Text("More"))
                    .accessibilityIdentifier("messageMore")
            }
            .palGlass(Capsule())
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .allowsHitTesting(visible)
        .onHover { inside in
            if inside { rowHover?.enter(.bar) } else { rowHover?.exit(.bar) }
        }
        .onAppear { PalPerf.event("message.hoverBar.built") }
        .onDisappear { rowHover?.exit(.bar) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageActionBar")
        .modifier(BarAccessibilityActions(
            react: showsReact ? { openMenu(from: reactFrame) } : nil,
            reply: layout.showsReply ? { actions.reply() } : nil,
            more: { openMenu(from: moreFrame) }
        ))
    }

    @ViewBuilder
    private func measure(_ visible: Bool, into frame: Binding<CGRect>) -> some View {
        if visible {
            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
        }
    }

    private func openMenu(from frame: CGRect) {
        shell.messageMenu = MacMessageMenuRequest(anchor: CGPoint(x: frame.minX, y: frame.maxY + 6), actions: actions)
    }

    private func glyph(_ name: String) -> some View {
        PalIcon(name, ink: .primary)
            .font(.system(size: 13, weight: .regular))
            .frame(width: MessageBarLayout.pitch, height: MessageBarLayout.height)
            .contentShape(Rectangle())
    }
}
#endif
