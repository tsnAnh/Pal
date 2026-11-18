#if os(macOS)
import AppKit
import PalClient

@MainActor
final class MacAppActivity: AppActivity {
    private var observers: [any NSObjectProtocol] = []

    // ScenePhase.active stays true on macOS for a visible window of an app that is not frontmost.
    var isFrontmost: Bool {
        NSApplication.shared.isActive && NSApplication.shared.keyWindow != nil
    }

    func observe(_ handler: @escaping @MainActor () -> Void) {
        let names: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didBecomeActiveNotification),
            (.default, NSApplication.didResignActiveNotification),
            (.default, NSWindow.didBecomeKeyNotification),
            (.default, NSWindow.didResignKeyNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        observers = names.map { center, name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }
}
#endif
