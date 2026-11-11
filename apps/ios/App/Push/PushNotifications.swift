import Foundation
import PalClient
import PalDiagnostics
import UserNotifications

@MainActor
final class PushNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    #if DEBUG
    static let environment = PushEnvironment.sandbox
    #else
    static let environment = PushEnvironment.production
    #endif

    private let center: UNUserNotificationCenter
    private let diagnostics: Diagnostics
    private var presence: ReachPresence?
    private var open: ((PushTarget) -> Void)?
    private var pendingTap: PushTarget?

    init(center: UNUserNotificationCenter = .current(), diagnostics: Diagnostics = .osLog()) {
        self.center = center
        self.diagnostics = diagnostics
        super.init()
        center.delegate = self
    }

    func attach(presence: ReachPresence, open: @escaping (PushTarget) -> Void) {
        self.presence = presence
        self.open = open
        if let pendingTap {
            self.pendingTap = nil
            open(pendingTap)
        }
    }

    func ensureRegistered() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }
        PlatformApplication.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) async {
        guard let token = PushToken(deviceToken: deviceToken),
              let bundleID = Bundle.main.bundleIdentifier,
              let registration = PushRegistration(token: token, environment: Self.environment, bundleID: bundleID)
        else {
            diagnostics.warning("push", "device token was not usable")
            return
        }
        await presence?.setPushRegistration(registration)
    }

    func didFailToRegister(_ error: any Error) {
        diagnostics.info("push", "remote notification registration failed: \(Diagnostics.describe(error))")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentation
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let target = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? PushWire.target(fromUserInfo: response.notification.request.content.userInfo)
            : nil
        Task { @MainActor in
            if let target { self.route(to: target) }
            completionHandler()
        }
    }

    private func route(to target: PushTarget) {
        guard let open else {
            pendingTap = target
            return
        }
        open(target)
    }
}
