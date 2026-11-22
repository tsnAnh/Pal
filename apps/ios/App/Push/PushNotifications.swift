import Foundation
import PalClient
import PalDiagnostics
import UserNotifications

@MainActor
final class PushNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    private let center: UNUserNotificationCenter
    private let diagnostics: Diagnostics
    private var presence: ReachPresence?
    private var open: ((PushTarget) -> Void)?
    private var pendingTap: PushTarget?
    private var badgeClearing: Task<Void, Never>?
    #if os(macOS)
    var restartForUpdate: (@MainActor () -> Void)?
    #endif

    init(center: UNUserNotificationCenter = .current(), diagnostics: Diagnostics = .osLog()) {
        self.center = center
        self.diagnostics = diagnostics
        super.init()
        center.delegate = self
        #if os(macOS)
        center.setNotificationCategories([UpdateNotification.category()])
        #endif
        badgeClearing = Task { [center, diagnostics] in
            for await _ in NotificationCenter.default.notifications(named: PlatformApplication.didBecomeActive) {
                do {
                    try await center.setBadgeCount(0)
                } catch {
                    diagnostics.info("push", "app icon badge was not cleared: \(Diagnostics.describe(error))")
                }
            }
        }
    }

    func attach(presence: ReachPresence, open: @escaping (PushTarget) -> Void) {
        self.presence = presence
        self.open = open
        PlatformApplication.followActivity(of: presence)
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
        let environment = await SignedPushEnvironment.resolve()
        guard let token = PushToken(deviceToken: deviceToken),
              let bundleID = Bundle.main.bundleIdentifier,
              let registration = PushRegistration(token: token, environment: environment, bundleID: bundleID)
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
        let restartsForUpdate = response.actionIdentifier == UpdateNotification.restartActionID
        let target = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? PushWire.target(fromUserInfo: response.notification.request.content.userInfo)
            : nil
        Task { @MainActor in
            if restartsForUpdate { self.restartForUpdateIfAvailable() }
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

    private func restartForUpdateIfAvailable() {
        #if os(macOS)
        restartForUpdate?()
        #endif
    }
}

enum UpdateNotification {
    static let categoryID = "pal.update"
    static let restartActionID = "pal.update.restart"
    static let requestID = "pal.update.ready"

    static func category() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: restartActionID, title: String(localized: "Restart"), options: [])],
            intentIdentifiers: []
        )
    }
}

#if os(macOS)
extension PushNotifications: UpdateNotices {
    func announceUpdate(version: String) async {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            diagnostics.info("update", "update \(version) is ready; notifications are off, so only the menu offers the restart")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pal \(version) is ready")
        content.body = String(localized: "Restart Pal to finish updating.")
        content.categoryIdentifier = UpdateNotification.categoryID
        do {
            try await center.add(UNNotificationRequest(identifier: UpdateNotification.requestID, content: content, trigger: nil))
        } catch {
            diagnostics.info("update", "update notice was not posted: \(Diagnostics.describe(error))")
        }
    }

    func withdrawUpdate() {
        center.removeDeliveredNotifications(withIdentifiers: [UpdateNotification.requestID])
        center.removePendingNotificationRequests(withIdentifiers: [UpdateNotification.requestID])
    }
}
#endif
