#if os(macOS)
import AppKit
import PalClient

@MainActor
final class MacAppActivity {
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var relay: Task<Void, Never>?

    // ScenePhase.active stays true on macOS for a visible window of an app that is not frontmost.
    private static var isFrontmost: Bool {
        NSApplication.shared.isActive && NSApplication.shared.keyWindow != nil
    }

    func follow(_ presence: ReachPresence) {
        stop()
        let (changes, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let names: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didBecomeActiveNotification),
            (.default, NSApplication.didResignActiveNotification),
            (.default, NSWindow.didBecomeKeyNotification),
            (.default, NSWindow.didResignKeyNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        observers = names.map { center, name in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { continuation.yield(Self.isFrontmost) }
            }
            return (center, token)
        }
        continuation.yield(Self.isFrontmost)
        relay = Task {
            for await frontmost in changes { await presence.setAppFrontmost(frontmost) }
        }
    }

    private func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        relay?.cancel()
    }
}
#endif
