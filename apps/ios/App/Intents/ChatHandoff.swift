import AppIntents
#if os(macOS)
import AppKit
#endif

extension AppIntent {
    @MainActor
    func continueInChat(_ report: ErrandReport, for target: BotEntity, in environment: IntentEnvironment) async throws {
        guard report.offersChat else { return }
        if #available(iOS 26, macOS 26, *) {
            guard systemContext.currentMode.canContinueInForeground else { return }
            try await continueInForeground(report.dialog)
        } else {
            try await requestConfirmation(actionName: .continue, dialog: report.dialog)
            #if os(macOS)
            NSApplication.shared.activate()
            #endif
        }
        environment.open(target)
    }
}
