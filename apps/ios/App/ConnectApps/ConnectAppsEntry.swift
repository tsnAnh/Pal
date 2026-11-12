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

    var id: String { name }
}

extension RosterModel {
    var customConnectorBots: [CustomConnectorBot] {
        bots.map { CustomConnectorBot(name: $0.name, displayName: $0.displayName) }
    }

    func currentBotName(forProfile profile: String?) -> String? {
        profile ?? bots.first(where: \.isDefault)?.name
    }
}

private struct DevicePermissionAlert: ViewModifier {
    let presenter: DevicePermissionPresenter

    func body(content: Content) -> some View {
        content.alert(
            presenter.pending.map { "\($0.botName) wants to \($0.ask.intent)" } ?? "",
            isPresented: Binding(get: { presenter.pending != nil }, set: { _ in }),
            presenting: presenter.pending
        ) { pending in
            Button(pending.status == .notDetermined ? "Continue" : "Open System Settings") { presenter.accept() }
                .accessibilityIdentifier("devicePermissionAccept")
            Button("Not Now", role: .cancel) { presenter.dismiss() }
                .accessibilityIdentifier("devicePermissionDismiss")
        } message: { pending in
            Text(pending.status == .notDetermined
                ? "macOS asks for your OK next. You can change this later in System Settings."
                : "macOS has this turned off for Pal. Allow it in System Settings, then ask \(pending.botName) again.")
        }
    }
}

extension View {
    func devicePermissionAlert(_ presenter: DevicePermissionPresenter) -> some View {
        modifier(DevicePermissionAlert(presenter: presenter))
    }
}
