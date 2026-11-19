#if os(macOS)
import PalBotProfile
import SwiftUI

struct MacConnectAppsPanel: View {
    let connection: ConnectionModel
    let hostPool: DeviceHostPool
    let roster: RosterModel
    let profile: String?
    let close: () -> Void

    @State private var model: ConnectAppsModel?

    var body: some View {
        Group {
            if let model { ConnectAppsScreen(model: model, close: close) }
        }
        .onAppear { if model == nil { model = makeModel() } }
    }

    private func makeModel() -> ConnectAppsModel {
        ConnectAppsModel(
            connection: connection,
            pool: hostPool,
            profile: profile,
            botName: roster.displayName(forProfile: profile),
            browser: WebAuthenticationBrowser(),
            bots: roster.customConnectorBots,
            currentBot: roster.currentBotName(forProfile: profile)
        )
    }
}
#endif
