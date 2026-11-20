#if os(macOS)
import AppKit
import PalDesign
import SwiftUI

private let messageBarGap: CGFloat = 8

extension View {
    func macRowHover(actions: MessageActions?) -> some View {
        modifier(MacRowHoverModifier(actions: actions))
    }
}

struct MacRowHoverModifier: ViewModifier {
    let actions: MessageActions?

    @Environment(MacShell.self) private var shell
    @State private var hover = RowHoverState()

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacRowTracker(hover: hover, actions: actions) { anchor in
                guard let actions else { return }
                shell.messageMenu = MacMessageMenuRequest(anchor: anchor, actions: actions)
            })
            .environment(\.rowHover, hover)
    }
}

struct MacMessageActionsModifier: ViewModifier {
    let side: MessageSide
    var placement: MessageChromePlacement = .beside
    let actions: MessageActions?

    func body(content: Content) -> some View {
        if let actions {
            switch side {
            case .user:
                content.overlay(alignment: .leading) {
                    MacMessageHoverBar(actions: actions)
                        .alignmentGuide(.leading) { $0[.trailing] + messageBarGap }
                }
            case .assistant where placement == .insideBubble:
                content.overlay(alignment: .topTrailing) {
                    MacMessageHoverBar(actions: actions)
                        .padding(.top, placement.barTopInset(hasReaction: actions.reaction != nil))
                        .padding(.trailing, MessageChromePlacement.insetFromEdge)
                }
            case .assistant:
                content.overlay(alignment: .trailing) {
                    MacMessageHoverBar(actions: actions)
                        .alignmentGuide(.trailing) { $0[.leading] - messageBarGap }
                }
            }
        } else {
            content
        }
    }
}

private struct MacRowTracker: NSViewRepresentable {
    let hover: RowHoverState
    let actions: MessageActions?
    let openMenu: (CGPoint) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        configure(view)
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        configure(view)
    }

    private func configure(_ view: TrackingView) {
        view.onChange = { [hover] in hover.setHovering($0) }
        view.openMenu = openMenu
        view.actions = actions
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var openMenu: (CGPoint) -> Void = { _ in }
        var actions: MessageActions?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                MessageMenuMonitor.shared.remove(self)
            } else {
                MessageMenuMonitor.shared.add(self)
            }
        }

        isolated deinit {
            MessageMenuMonitor.shared.remove(ObjectIdentifier(self))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }

        func opensMenu(_ event: NSEvent) -> Bool {
            guard event.window === window, actions != nil else { return false }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isMenuClick, bounds.contains(convert(event.locationInWindow, from: nil)),
                  let hit = window?.contentView?.hitTest(event.locationInWindow)
            else { return false }
            return Bundle(for: type(of: hit)) != Bundle.main
        }

        func showMenu(for event: NSEvent) {
            guard let height = window?.contentView?.bounds.height else { return }
            openMenu(CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y))
        }
    }
}

@MainActor
private final class MessageMenuMonitor {
    static let shared = MessageMenuMonitor()

    private struct Entry {
        weak var view: MacRowTracker.TrackingView?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    func add(_ view: MacRowTracker.TrackingView) {
        entries[ObjectIdentifier(view)] = Entry(view: view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            for case let view? in self.entries.values.map(\.view) where view.opensMenu(event) {
                view.showMenu(for: event)
                return nil
            }
            return event
        }
    }

    func remove(_ view: MacRowTracker.TrackingView) {
        remove(ObjectIdentifier(view))
    }

    func remove(_ id: ObjectIdentifier) {
        entries[id] = nil
        guard entries.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
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

private struct MacMessageHoverBar: View {
    let actions: MessageActions

    private static let pitch: CGFloat = 25

    private enum Control: Hashable {
        case react
        case reply
        case more
    }

    @Environment(MacShell.self) private var shell
    @Environment(\.rowHover) private var rowHover
    @FocusState private var focus: Control?
    @State private var reactFrame = CGRect.zero
    @State private var moreFrame = CGRect.zero

    private var isShown: Bool {
        rowHover?.isHovering == true || focus != nil || shell.messageMenu?.actions.rowID == actions.rowID
    }

    var body: some View {
        let visible = isShown
        let showsReact = !actions.isOwnFailed && (!visible || actions.canReact())
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 0) {
                if showsReact {
                    Button { openMenu(from: reactFrame) } label: { glyph("face.smiling") }
                        .buttonStyle(.plain)
                        .focused($focus, equals: .react)
                        .background { measure(visible, into: $reactFrame) }
                        .help(String(localized: "React"))
                        .accessibilityLabel(Text("React"))
                        .accessibilityIdentifier("messageReact")
                }
                if !actions.isOwnFailed {
                    Button { actions.reply() } label: { glyph("arrow.uturn.left") }
                        .buttonStyle(.plain)
                        .focused($focus, equals: .reply)
                        .help(String(localized: "Reply"))
                        .accessibilityLabel(Text("Reply"))
                        .accessibilityIdentifier("messageReply")
                }
                Button { openMenu(from: moreFrame) } label: { glyph("ellipsis") }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .more)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageActionBar")
        .modifier(BarAccessibilityActions(
            react: showsReact ? { openMenu(from: reactFrame) } : nil,
            reply: actions.isOwnFailed ? nil : { actions.reply() },
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
            .frame(width: Self.pitch, height: 26)
            .contentShape(Rectangle())
    }
}
#endif
