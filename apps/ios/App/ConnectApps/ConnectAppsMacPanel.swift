#if os(macOS)
import PalBotProfile
import SwiftUI

struct MacConnectAppsPanel: View {
    let close: () -> Void

    @LazyState private var model: ConnectAppsModel

    init(connection: ConnectionModel, hostPool: DeviceHostPool, roster: RosterModel, profile: String?, close: @escaping () -> Void) {
        self.close = close
        _model = LazyState {
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

    var body: some View {
        ConnectAppsScreen(model: model, close: close)
    }
}
#endif
