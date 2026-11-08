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

private struct DeviceConsentAlert: ViewModifier {
    let presenter: DeviceConsentPresenter

    func body(content: Content) -> some View {
        content.alert(
            presenter.pending.map { "Let \($0.botName) use your \($0.ask.connectorTitle)?" } ?? "",
            isPresented: Binding(get: { presenter.pending != nil }, set: { _ in }),
            presenting: presenter.pending
        ) { _ in
            Button("Allow") { presenter.answer(true) }
                .accessibilityIdentifier("deviceConsentAllow")
            Button("Don't Allow", role: .cancel) { presenter.answer(false) }
                .accessibilityIdentifier("deviceConsentDeny")
        } message: { pending in
            Text("\(pending.botName) wants to \(pending.ask.intent).")
        }
    }
}

extension View {
    func deviceConsentAlert(_ presenter: DeviceConsentPresenter) -> some View {
        modifier(DeviceConsentAlert(presenter: presenter))
    }
}
