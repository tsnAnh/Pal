#if os(macOS)
import AppKit
import PalDesign
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
        weak var view: MacHoverTracker.TrackingView?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    func add(_ view: MacHoverTracker.TrackingView) {
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

    func remove(_ view: MacHoverTracker.TrackingView) {
        remove(ObjectIdentifier(view))
    }

    func remove(_ id: ObjectIdentifier) {
        entries[id] = nil
        guard entries.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
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
            .palGlass(Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageActionBar")
    }

    private func open(from frame: CGRect) {
        shell.messageMenu = MacMessageMenuRequest(anchor: CGPoint(x: frame.minX, y: frame.maxY + 6), actions: actions)
    }

    private func glyph(_ name: String) -> some View {
        PalIcon(name, ink: .secondary)
            .font(.system(size: 13, weight: .regular))
            .frame(width: Self.pitch, height: 26)
            .contentShape(Rectangle())
    }
}
#endif
