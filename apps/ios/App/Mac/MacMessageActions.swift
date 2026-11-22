#if os(macOS)
import AppKit
import PalDesign
import SwiftUI

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
            .overlayPreferenceValue(MessageCarrierKey.self) { carrier in
                if let carrier, let actions {
                    MacMessageChrome(carrier: carrier, actions: actions)
                }
            }
            .environment(\.rowHover, hover)
    }
}

struct MessageCarrier {
    let bubble: Anchor<CGRect>
    let slot: MessageChromePlacement.Slot
}

struct MessageCarrierKey: PreferenceKey {
    static var defaultValue: MessageCarrier? { nil }

    static func reduce(value: inout MessageCarrier?, nextValue: () -> MessageCarrier?) {
        value = value ?? nextValue()
    }
}

struct MacMessageActionsModifier: ViewModifier {
    let side: MessageSide
    var placement: MessageChromePlacement = .beside
    let actions: MessageActions?

    func body(content: Content) -> some View {
        if actions != nil {
            content.anchorPreference(key: MessageCarrierKey.self, value: .bounds) { [side, placement] bubble in
                MessageCarrier(bubble: bubble, slot: MessageChromePlacement.Slot(side: side, preferred: placement))
            }
        } else {
            content
        }
    }
}

private struct MacMessageChrome: View {
    let carrier: MessageCarrier
    let actions: MessageActions

    @Environment(MacShell.self) private var shell
    @Environment(\.rowHover) private var rowHover
    @FocusState private var focus: MessageBarControl?

    private var isShown: Bool {
        rowHover?.isHovering == true || focus != nil || shell.messageMenu?.actions.rowID == actions.rowID
    }

    var body: some View {
        let shown = isShown
        let barBuilt = shown || AssistiveAccess.shared.isActive
        let layout = MessageBarLayout(isOwnFailed: actions.isOwnFailed, canReact: !shown || actions.canReact())
        Group {
            if barBuilt || actions.reaction != nil {
                GeometryReader { proxy in
                    MessageChromeLayout(
                        bubble: proxy[carrier.bubble],
                        region: CGRect(origin: .zero, size: proxy.size),
                        slot: carrier.slot,
                        hasReaction: actions.reaction != nil,
                        barSize: layout.size
                    ) {
                        if barBuilt {
                            MacMessageHoverBar(actions: actions, layout: layout, visible: shown, focus: $focus)
                                .layoutValue(key: ChromeRoleKey.self, value: .bar)
                                .transition(.opacity)
                        }
                        if let reaction = actions.reaction {
                            MessageReactionBadge(emoji: reaction)
                                .layoutValue(key: ChromeRoleKey.self, value: .badge)
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: barBuilt)
    }
}

private enum ChromeRole {
    case bar
    case badge
}

private struct ChromeRoleKey: LayoutValueKey {
    static let defaultValue = ChromeRole.bar
}

private struct MessageChromeLayout: Layout {
    let bubble: CGRect
    let region: CGRect
    let slot: MessageChromePlacement.Slot
    let hasReaction: Bool
    let barSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: region.size)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let resolved = MessageChromePlacement.place(
            bubble: bubble, region: region, slot: slot, bar: barSize, hasReaction: hasReaction
        )
        for subview in subviews {
            switch subview[ChromeRoleKey.self] {
            case .bar:
                subview.place(at: bounds.origin.offset(by: resolved.frames.bar.origin), proposal: ProposedViewSize(barSize))
            case .badge:
                guard let badge = resolved.frames.badge else { continue }
                subview.place(at: bounds.origin.offset(by: badge.origin), proposal: ProposedViewSize(badge.size))
            }
        }
    }
}

private extension CGPoint {
    func offset(by other: CGPoint) -> CGPoint {
        CGPoint(x: x + other.x, y: y + other.y)
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
        view.onChange = { [hover] in
            if $0 { hover.enter(.message) } else { hover.exit(.message) }
        }
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
            guard trackingAreas.isEmpty else { return }
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
#endif
