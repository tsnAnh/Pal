#if os(macOS)
import AppKit
import HermesDesign
import SwiftUI

struct MacMessageActionsModifier: ViewModifier {
    let side: MessageSide
    let actions: MessageActions?

    @Environment(MacShell.self) private var shell
    @State private var bubbleHovered = false
    @State private var barHovered = false

    private var showsBar: Bool {
        guard let actions else { return false }
        return (bubbleHovered || barHovered || shell.messageMenu?.actions.rowID == actions.rowID)
    }

    func body(content: Content) -> some View {
        if let actions {
            content
                .background(MacHoverTracker(isHovering: $bubbleHovered, actions: actions) { anchor in
                    shell.messageMenu = MacMessageMenuRequest(anchor: anchor, actions: actions)
                })
                .overlay(alignment: side == .user ? .leading : .trailing) {
                    if showsBar {
                        MacMessageHoverBar(side: side, actions: actions)
                            .frame(width: MacMessageHoverBar.span, alignment: side == .user ? .trailing : .leading)
                            .onHover { barHovered = $0 }
                            .offset(x: side == .user ? -MacMessageHoverBar.span : MacMessageHoverBar.span)
                    }
                }
        } else {
            content
        }
    }
}

private struct MacHoverTracker: NSViewRepresentable {
    @Binding var isHovering: Bool
    let actions: MessageActions
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
        view.onChange = { isHovering = $0 }
        view.openMenu = openMenu
        view.actions = actions
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var openMenu: (CGPoint) -> Void = { _ in }
        var actions: MessageActions?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, self.opensMenu(event) else { return event }
                self.showMenu(for: event)
                return nil
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
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

        private func opensMenu(_ event: NSEvent) -> Bool {
            guard event.window === window, actions != nil else { return false }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isMenuClick, bounds.contains(convert(event.locationInWindow, from: nil)),
                  let hit = window?.contentView?.hitTest(event.locationInWindow)
            else { return false }
            return Bundle(for: type(of: hit)) != Bundle.main
        }

        private func showMenu(for event: NSEvent) {
            guard let height = window?.contentView?.bounds.height else { return }
            openMenu(CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y))
        }
    }
}

private struct MacMessageHoverBar: View {
    let side: MessageSide
    let actions: MessageActions

    static let span: CGFloat = 80
    private static let pitch: CGFloat = 25

    @Environment(MacShell.self) private var shell
    @State private var reactFrame = CGRect.zero
    @State private var moreFrame = CGRect.zero

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 0) {
                if actions.canReact() {
                    Button { open(from: reactFrame) } label: { glyph("face.smiling") }
                        .buttonStyle(.plain)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reactFrame = $0 }
                        .help(String(localized: "React"))
                        .accessibilityLabel(Text("React"))
                        .accessibilityIdentifier("messageReact")
                }
                Button { actions.reply() } label: { glyph("arrow.uturn.left") }
                    .buttonStyle(.plain)
                    .help(String(localized: "Reply"))
                    .accessibilityLabel(Text("Reply"))
                    .accessibilityIdentifier("messageReply")
                Button { open(from: moreFrame) } label: { glyph("ellipsis") }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { moreFrame = $0 }
                    .help(String(localized: "More"))
                    .accessibilityLabel(Text("More"))
                    .accessibilityIdentifier("messageMore")
            }
            .palGlass(Capsule(), tint: PalTokens.elevated.opacity(0.9))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageActionBar")
    }

    private func open(from frame: CGRect) {
        shell.messageMenu = MacMessageMenuRequest(anchor: CGPoint(x: frame.minX, y: frame.maxY + 6), actions: actions)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(PalTokens.textSecondary)
            .frame(width: Self.pitch, height: 26)
            .contentShape(Rectangle())
    }
}
#endif
