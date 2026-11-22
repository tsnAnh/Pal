import PalSettings
import SwiftUI

extension View {
    func ownerIntro(hub: SettingsHub, connection: ConnectionModel) -> some View {
        modifier(OwnerIntroPresenter(hub: hub, connection: connection))
    }
}

private struct OwnerIntroPresenter: ViewModifier {
    let hub: SettingsHub
    let connection: ConnectionModel

    private struct Trigger: Equatable {
        let account: String
        let connected: Bool
        let pending: Bool
    }

    #if os(macOS)
    private static let forcedByLaunch = ProcessInfo.processInfo.arguments.contains("-hermes-test-owner-intro")

    @State private var intro: OwnerIntroModel?

    private var isPending: Bool { connection.ownerIntroPending || Self.forcedByLaunch }

    private var trigger: Trigger {
        Trigger(account: connection.accountKey, connected: connection.isConnected, pending: isPending)
    }

    func body(content: Content) -> some View {
        content
            .task(id: trigger) { await settle() }
            .macSheet(isPresented: Binding(get: { intro != nil }, set: { if !$0 { intro?.escape() } }), size: .full) {
                if let intro { OwnerIntroSheet(model: intro) }
            }
    }

    private func settle() async {
        guard connection.isConnected else { return }
        await hub.owner.load()
        guard isPending, hub.owner.hasLoaded, intro == nil else { return }
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
