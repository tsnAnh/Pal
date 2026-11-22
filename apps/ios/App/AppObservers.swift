import PalClient
import PalConnect
import PalDevice
import SwiftUI

struct AppObservers: ViewModifier {
    let model: ConnectionModel
    let roster: RosterModel
    let router: AppRouter
    let hostPool: DeviceHostPool
    let autoApprove: ActionAutoApprove
    let directory: BotDirectory
    let push: PushNotifications
    let scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isConnected, initial: true) { _, connected in
                if connected { Task { await push.ensureRegistered() } }
            }
            .onChange(of: roster.bots) { _, bots in
                PushAvatarSync.shared.sync(bots)
                Task { await directory.publish(bots) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.restore() } }
            }
            .onChange(of: model.phase) { _, phase in
                guard phase == .signedOut else { return }
                autoApprove.forget()
                roster.reset()
                router.popToRoot()
                Task { await hostPool.reset() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.report(attention: ReachAttention(sceneIsActive: phase == .active))
            }
    }
}
