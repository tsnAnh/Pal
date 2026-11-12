import PalBotProfile
import PalDesign
import SwiftUI

struct PalServiceScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: GatewayServiceModel
    @State private var host: HostServerModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: GatewayServiceModel(client: GatewayServiceClient(gateway: gateway)))
        _host = State(initialValue: HostServerModel(client: HostServerClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: "Server", identifier: "hermesServiceScreen", back: back) {
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
            if model.loadFailed || model.isUnreachable {
                GroupedCard(accessibilityIdentifier: "hermesServiceRetryCard") {
                    SettingsRow(
                        title: "Check again", trailing: .none, accessibilityIdentifier: "hermesServiceRetryRow",
                        action: { Task { await model.load() } })
                        .disabled(model.isBusy)
                }
            }
            CardFootnote(model.noticeText ?? footnote, accessibilityIdentifier: "hermesServiceFootnote")
            ServerHealthSection(host: host)
            ServerLogSection(host: host)
        }
        .task {
            await model.load()
            await host.refresh()
        }
        .refreshable {
            await model.load()
            await host.refresh()
        }
    }

    @ViewBuilder
    private func actions(_ info: GatewayServiceInfo) -> some View {
        if info.canRestart || info.canInstall {
            GroupedCard(accessibilityIdentifier: "hermesServiceActionCard") {
                if info.canRestart {
                    SettingsRow(
                        title: model.activity == .restarting ? restartingTitle : "Restart Pal",
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

    private var restartingTitle: String {
        guard let progress = model.progress else { return "Restarting…" }
        return "Restarting… waiting for Pal (\(progress.attempt) of \(progress.limit))"
    }

    private var stateText: String {
        if model.isUnreachable { return "Not responding" }
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
