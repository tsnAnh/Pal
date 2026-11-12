#if os(macOS)
import AppKit
import PalDevice

@MainActor
final class InputSafety: NSObject {
    private static let lingerSeconds = 5.0

    static let pausedKey = "dev.tsnanh.hermes.input-paused"

    private let controller: InputController
    private let defaults: UserDefaults
    private var statusItem: NSStatusItem?
    private let stopItem = NSMenuItem(title: "Stop", action: #selector(InputSafety.stopTapped), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(InputSafety.resumeTapped), keyEquivalent: "")
    private var monitors: [Any] = []
    private var detector = EscapeBurstDetector()
    private var hideTask: Task<Void, Never>?

    init(controller: InputController = .shared, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
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
        if defaults.bool(forKey: Self.pausedKey) { controller.stop() }
    }

    private func pressedEscape(at time: TimeInterval) {
        guard detector.record(at: time) else { return }
        stopEverything()
    }

    @objc private func stopTapped() {
        stopEverything()
    }

    @objc private func resumeTapped() {
        defaults.set(false, forKey: Self.pausedKey)
        controller.rearm()
    }

    private func stopEverything() {
        defaults.set(true, forKey: Self.pausedKey)
        controller.stop()
    }

    private func show(_ activity: InputActivity) {
        hideTask?.cancel()
        hideTask = nil
        let item = statusItem ?? makeItem()
        switch activity {
        case .began: item.button?.title = " Pal is controlling this Mac"
        case .ended: break
        case .stopped: item.button?.title = " Pal control stopped"
        case .resumed: item.button?.title = " Pal control resumed"
        }
        stopItem.isEnabled = !controller.isStopped
        resumeItem.isEnabled = controller.isStopped
        guard activity != .began, !controller.isStopped else { return }
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
        menu.autoenablesItems = false
        stopItem.target = self
        resumeItem.target = self
        menu.addItem(stopItem)
        menu.addItem(resumeItem)
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
