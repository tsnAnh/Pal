#if os(macOS)
import AppKit
import PalDevice

@MainActor
final class InputSafety: NSObject {
    private static let lingerSeconds = 5.0

    private let controller: InputController
    private let switchOff: @MainActor () async -> Void
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var detector = EscapeBurstDetector()
    private var hideTask: Task<Void, Never>?

    init(controller: InputController = .shared, switchOff: @escaping @MainActor () async -> Void) {
        self.controller = controller
        self.switchOff = switchOff
    }

    func start() {
        guard monitors.isEmpty else { return }
        controller.observe { [weak self] activity in
            Task { @MainActor in self?.show(activity) }
        }
        let tag = CGEventInputSource.eventTag
        let escape: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != tag else { return }
            let time = event.timestamp
            Task { @MainActor in self?.pressedEscape(at: time) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            escape(event)
            return event
        }) { monitors.append(local) }
    }

    private func pressedEscape(at time: TimeInterval) {
        guard detector.record(at: time) else { return }
        stopEverything()
    }

    @objc private func stopTapped() {
        stopEverything()
    }

    private func stopEverything() {
        controller.stop()
        Task { await switchOff() }
    }

    private func show(_ activity: InputActivity) {
        hideTask?.cancel()
        hideTask = nil
        let item = statusItem ?? makeItem()
        switch activity {
        case .began: item.button?.title = " Pal is controlling this Mac"
        case .ended: break
        case .stopped: item.button?.title = " Pal control stopped"
        }
        guard activity != .began else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lingerSeconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)
        item.button?.setAccessibilityIdentifier("inputControlIndicator")
        let menu = NSMenu()
        let stop = NSMenuItem(title: "Stop", action: #selector(stopTapped), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu
        statusItem = item
        return item
    }

    private func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }
}
#endif
