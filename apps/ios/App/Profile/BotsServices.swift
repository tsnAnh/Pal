import HermesBotProfile
import HermesConnect
import HermesDiagnostics
import HermesRFB

struct BotsServices: Sendable {
    let profiles: BotProfileService
    let library: LibraryService
    let routines: RoutineService
    let slack: SlackService
    let connectCatalog: @Sendable (String) async throws -> ConnectCatalog
    let computer: ComputerService
    let openDisplayStream: @Sendable (ComputerObservation) async throws -> any RFBTransport

    @MainActor
    init(connection: ConnectionModel) {
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        profiles = BotProfileService(gateway: gateway, diagnostics: .osLog())
        library = LibraryService(gateway: gateway)
        routines = RoutineService(gateway: gateway)
        slack = SlackService(gateway: gateway)
        connectCatalog = { profile in
            try await ConnectAppsService(rpc: ConnectionRPC(model: connection), profile: profile).load()
        }
        computer = ComputerService(gateway: gateway)
        openDisplayStream = { observation in
            try await connection.displayTransport(path: observation.path, ticket: observation.ticket)
        }
    }
}

@MainActor
final class BotsKit {
    let services: BotsServices
    let sharer: TemplateSharer

    init(connection: ConnectionModel) {
        let services = BotsServices(connection: connection)
        self.services = services
        sharer = TemplateSharer(services: services)
    }
}
