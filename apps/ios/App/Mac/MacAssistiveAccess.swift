#if os(macOS)
import AppKit
import Observation

@MainActor
@Observable
final class AssistiveAccess {
    static let shared = AssistiveAccess()

    private(set) var isActive: Bool
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?
    @ObservationIgnored private var activationTask: Task<Void, Never>?

    private init() {
        isActive = Self.current
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        activationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.refresh()
            }
        }
    }

    private static var current: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled
    }

    private func refresh() {
        let now = Self.current
        guard now != isActive else { return }
        isActive = now
    }
}
#endif
