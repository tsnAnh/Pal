#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct MacServerSection: View {
    let hub: SettingsHub

    @State private var service: GatewayServiceModel?
    @State private var host: HostServerModel?

    private static let sinceFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        MacSectionPage(section: .server) {
            if let service, let host {
                content(service: service, host: host)
            } else {
                MacCard { MacLoading() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if service == nil || host == nil {
            let connection = hub.connection
            let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
            service = GatewayServiceModel(client: GatewayServiceClient(gateway: gateway), surfaces: connection.surfaces)
            host = HostServerModel(client: HostServerClient(gateway: gateway), surfaces: connection.surfaces)
        }
        await service?.load()
        await host?.refresh()
    }

    @ViewBuilder
    private func content(service: GatewayServiceModel, host: HostServerModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MacCard(identifier: "hermesServiceStateCard") {
                MacRow(title: String(localized: "Status"), identifier: "hermesServiceState") { value(Text(service.stateText)) }
                if let since = service.info?.startedAt {
                    MacRow(title: String(localized: "Running since"), identifier: "hermesServiceSince") {
                        value(Text(since, format: Self.sinceFormat))
                    }
                }
            }
            restart(service)
            MacFootnote(text: service.noticeText ?? footnote(service), identifier: "hermesServiceFootnote")
                .padding(.top, -4)
        }
        if hub.connection.isLocalEngine {
            LocalEngineSettingsSection(engine: hub.connection.localEngine)
        }
        ServerHealthSection(host: host)
        ServerLogSection(host: host)
    }

    private func footnote(_ service: GatewayServiceModel) -> String {
        hub.connection.isLocalEngine && service.info?.reason == nil && !service.loadFailed
            ? String(localized: "The Pal service on this Mac.")
            : service.footnote
    }

    @ViewBuilder
    private func restart(_ service: GatewayServiceModel) -> some View {
        if let info = service.info, info.canRestart {
            MacCard(identifier: "hermesServiceActionCard") {
                Button {
                    Task { await service.restart() }
                } label: {
                    MacRow(
                        title: service.activity == .restarting ? service.restartingTitle : String(localized: "Restart Pal"),
                        subtitle: info.activeRuns > 0 ? String(localized: "A chat is running. Restart once it finishes.") : nil,
                        identifier: "hermesServiceRestartRow"
                    ) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(service.isBusy)
            }
        }
    }

    private func value(_ text: Text) -> some View {
        text
            .font(.system(size: 11.5))
            .foregroundStyle(PalTokens.textSecondary)
    }
}
#endif
