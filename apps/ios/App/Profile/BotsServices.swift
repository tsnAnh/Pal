import HermesBotProfile
import HermesDiagnostics

struct BotsServices: Sendable {
    let profiles: BotProfileService
    let library: LibraryService
    let routines: RoutineService
    let slack: SlackService

    @MainActor
    init(connection: ConnectionModel) {
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        profiles = BotProfileService(gateway: gateway, diagnostics: .osLog())
        library = LibraryService(gateway: gateway)
        routines = RoutineService(gateway: gateway)
        slack = SlackService(gateway: gateway)
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
