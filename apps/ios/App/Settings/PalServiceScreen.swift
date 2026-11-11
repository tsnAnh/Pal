import PalBotProfile
import PalDesign
import SwiftUI

struct PalServiceScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: GatewayServiceModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: GatewayServiceModel(client: GatewayServiceClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: "Pal service", identifier: "hermesServiceScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "hermesServiceStateCard") {
                SettingsRow.value("Status", value: stateText, accessibilityIdentifier: "hermesServiceState")
                if let since = model.info?.startedAt {
                    SettingsRow.value(
                        "Running since", value: since.formatted(date: .abbreviated, time: .shortened),
                        accessibilityIdentifier: "hermesServiceSince")
                }
            }
            if let info = model.info {
                actions(info)
            }
            CardFootnote(model.noticeText ?? footnote, accessibilityIdentifier: "hermesServiceFootnote")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func actions(_ info: GatewayServiceInfo) -> some View {
        if info.canRestart || info.canInstall {
            GroupedCard(accessibilityIdentifier: "hermesServiceActionCard") {
                if info.canRestart {
                    SettingsRow(
                        title: model.activity == .restarting ? "Restarting…" : "Restart Pal",
                        subtitle: info.activeRuns > 0 ? "A chat is running. Restart once it finishes." : nil, trailing: .none,
                        accessibilityIdentifier: "hermesServiceRestartRow",
                        action: { Task { await model.restart() } }
                    )
                    .disabled(model.isBusy)
                }
                if info.canInstall {
                    SettingsRow(
                        title: model.activity == .installing ? "Installing…" : "Start Pal automatically",
                        subtitle: "Keeps Pal and its scheduled jobs running when you sign in.", trailing: .none,
                        accessibilityIdentifier: "hermesServiceInstallRow",
                        action: { Task { await model.install() } }
                    )
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private var stateText: String {
        guard let info = model.info else { return model.loadFailed ? "Unavailable" : " " }
        return switch info.state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .notInstalled: "Not installed"
        case .restartNeeded: "Restart needed"
        case .unsupported: "Not supported here"
        case .unknown: "Unknown"
        }
    }

    private var footnote: String {
        if model.loadFailed { return "Couldn't reach Pal. Pull to refresh." }
        return model.info?.reason ?? "The Pal service on the computer you're connected to."
    }
}
