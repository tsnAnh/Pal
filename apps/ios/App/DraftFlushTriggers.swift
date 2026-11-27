import Foundation
import PalChat

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class DraftFlushTriggers: Sendable {
    nonisolated(unsafe) private var tokens: [any NSObjectProtocol] = []

    init(store: DraftStore) {
        #if os(macOS)
        let names: [Notification.Name] = [
            NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification, NSWindow.willCloseNotification,
        ]
        #else
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification,
        ]
        #endif
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in store.flush() }
        }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
