import PalChat
import PalSettings
import SwiftUI

extension View {
    func ownerIntro(hub: SettingsHub, connection: ConnectionModel, router: AppRouter) -> some View {
        modifier(OwnerIntroPresenter(hub: hub, connection: connection, router: router))
    }
}

private struct OwnerIntroPresenter: ViewModifier {
    let hub: SettingsHub
    let connection: ConnectionModel
    let router: AppRouter

    private struct Trigger: Equatable {
        let account: String
        let connected: Bool
        let pending: Bool
    }

    #if os(macOS)
    private static let forcedByLaunch = ProcessInfo.processInfo.arguments.contains("-hermes-test-owner-intro")

    private struct GreetingTrigger: Equatable {
        let run: LocalFirstRun
        let introPending: Bool
        let rosterLoaded: Bool
    }

    @State private var intro: OwnerIntroModel?

    private var isPending: Bool { connection.ownerIntroPending || Self.forcedByLaunch }

    private var trigger: Trigger {
        Trigger(account: connection.accountKey, connected: connection.isConnected, pending: isPending)
    }

    func body(content: Content) -> some View {
        content
            .task(id: trigger) { await settle() }
            .task(id: GreetingTrigger(run: connection.localFirstRun, introPending: connection.ownerIntroPending, rosterLoaded: hub.roster.isLoaded)) {
                greetIfFirstRunIsDone()
            }
            .macSheet(isPresented: Binding(get: { intro != nil }, set: { if !$0 { intro?.escape() } }), size: .full) {
                if let intro { OwnerIntroSheet(model: intro) }
            }
    }

    private func settle() async {
        guard connection.isConnected else { return }
        await hub.owner.load()
        guard hub.owner.hasLoaded else {
            if case .introducing = connection.localFirstRun { connection.ownerIntroHandled() }
            return
        }
        guard isPending, intro == nil else { return }
        let store = OwnerIntroStore(account: connection.accountKey)
        guard hub.owner.name.isEmpty, !store.isDismissed else {
            connection.ownerIntroHandled()
            return
        }
        intro = OwnerIntroModel(
            owner: hub.owner,
            suggestedName: OwnerIntroModel.suggestedName(fullName: NSFullUserName())
        ) { _ in
            store.dismiss()
            intro = nil
            connection.ownerIntroHandled()
        }
    }

    private func greetIfFirstRunIsDone() {
        guard case .introducing(let greets) = connection.localFirstRun, !connection.ownerIntroPending, intro == nil else { return }
        guard greets else {
            connection.localFirstRunSettled()
            return
        }
        guard hub.roster.isLoaded else { return }
        if let bot = hub.roster.primaryBot {
            hub.roster.stageIntro(.ownerWelcome(ownerName: hub.owner.name), for: bot.name)
            router.openChat(botName: bot.name)
        }
        connection.localFirstRunSettled()
    }
    #else
    private var trigger: Trigger {
        Trigger(account: connection.accountKey, connected: connection.isConnected, pending: false)
    }

    func body(content: Content) -> some View {
        content.task(id: trigger) {
            guard connection.isConnected else { return }
            await hub.owner.load()
        }
    }
    #endif
}
