#if os(macOS)
import AppKit
import SwiftUI

struct MacWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.placeTrafficLights()
    }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var clickMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            removeClickMonitor()
            guard let window else { return }
            installClickMonitor(for: window)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeTrafficLights() }
                }
            }
            placeTrafficLights()
            DispatchQueue.main.async { [weak self] in self?.placeTrafficLights() }
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            removeClickMonitor()
        }

        private func installClickMonitor(for window: NSWindow) {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] event in
                MainActor.assumeIsolated {
                    if let self, let window, event.window === window, event.clickCount == 2, self.isEmptyTitleArea(event, in: window) {
                        Self.performTitleBarDoubleClick(on: window)
                    }
                }
                return event
            }
        }

        private func removeClickMonitor() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        private func isEmptyTitleArea(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard !window.styleMask.contains(.fullScreen), let content = window.contentView else { return false }
            let point = event.locationInWindow
            guard point.y >= content.frame.height - MacMetrics.topBarHeight else { return false }
            let screenPoint = window.convertPoint(toScreen: point)
            return !Self.isControl(content.accessibilityHitTest(screenPoint))
        }

        private static let controlRoles: Set<NSAccessibility.Role> = [
            .button, .popUpButton, .menuButton, .menuItem, .textField, .textArea, .checkBox, .radioButton,
            .slider, .incrementor, .comboBox, .link, .tabGroup,
        ]

        private static func isControl(_ element: Any?) -> Bool {
            var current = element as? NSAccessibilityProtocol
            var depth = 0
            while let node = current, depth < 8 {
                if let role = node.accessibilityRole(), controlRoles.contains(role) { return true }
                current = node.accessibilityParent() as? NSAccessibilityProtocol
                depth += 1
            }
            return false
        }

        private static func performTitleBarDoubleClick(on window: NSWindow) {
            let defaults = UserDefaults.standard
            let action = defaults.string(forKey: "AppleActionOnDoubleClick")
                ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
            switch action {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }

        func placeTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let buttons = kinds.compactMap { window.standardWindowButton($0) }
            guard buttons.count == kinds.count, let container = buttons[0].superview else { return }
            for (index, button) in buttons.enumerated() {
                let centerX = MacMetrics.trafficLightCenter.x + CGFloat(index) * MacMetrics.trafficLightPitch
                let centerY = container.isFlipped
                    ? MacMetrics.trafficLightCenter.y
                    : container.bounds.height - MacMetrics.trafficLightCenter.y
                let origin = NSPoint(x: centerX - button.frame.width / 2, y: centerY - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
#endif
