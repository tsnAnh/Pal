import PalDesign
import PalDevice
import SwiftUI

enum ConnectAppsLaunch {
    static let argument = "-hermes-open-connect-apps"
}

extension RosterModel {
    func displayName(forProfile profile: String?) -> String {
        if let profile, let bot = bot(named: profile) { return bot.displayName }
        return bots.first(where: \.isDefault)?.displayName ?? "Your bot"
    }
}

struct CustomConnectorBot: Identifiable, Equatable {
    let name: String
    let displayName: String
    let spec: BotAvatarSpec?

    var id: String { name }
}

extension RosterModel {
    var customConnectorBots: [CustomConnectorBot] {
        bots.map { CustomConnectorBot(name: $0.name, displayName: $0.displayName, spec: $0.spec) }
    }

    func currentBotName(forProfile profile: String?) -> String? {
        profile ?? bots.first(where: \.isDefault)?.name
    }
}

private struct DevicePermissionAlert: ViewModifier {
    let presenter: DevicePermissionPresenter

    func body(content: Content) -> some View {
        content.macAlert(item: Binding(get: { presenter.pending }, set: { _ in })) { pending in
            MacDialogContent(
                "\(pending.botName) wants to \(pending.ask.intent)",
                message: pending.status == .notDetermined
                    ? String(localized: "macOS asks for your OK next. You can change this later in System Settings.")
                    : String(localized: "macOS has this turned off for Pal. Allow it in System Settings, then ask \(pending.botName) again."),
                actions: [
                    MacDialogAction(
                        pending.status == .notDetermined ? String(localized: "Continue") : String(localized: "Open System Settings"),
                        identifier: "devicePermissionAccept"
                    ) { presenter.accept() },
                    MacDialogAction(String(localized: "Not Now"), role: .cancel, identifier: "devicePermissionDismiss") { presenter.dismiss() },
                ]
            )
        }
    }
}

extension View {
    func devicePermissionAlert(_ presenter: DevicePermissionPresenter) -> some View {
        modifier(DevicePermissionAlert(presenter: presenter))
    }
}
